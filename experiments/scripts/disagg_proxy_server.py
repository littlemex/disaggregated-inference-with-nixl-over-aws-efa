#!/usr/bin/env python3
"""
Disaggregated Prefill Proxy Server v3 for NIXL over EFA

Phase 10a: KV-Cache NIXL 転送を正しく動作させるための修正版プロキシ。

v1 からの主な変更点:
- Prefill リクエストに kv_transfer_params: {"do_remote_decode": true} を追加
- Prefill レスポンスから kv_transfer_params を取得（remote_block_ids 等）
- Decode リクエストに Prefill レスポンスの kv_transfer_params を渡す

v2 からの主な変更点:
- [P0-4] Proxy 内部タイムスタンプの追加（Prefill/Decode 各フェーズの時間測定）

v3 からの主な変更点（2026-02-27）:
- [P0-00] ClientSession の再利用による接続プーリングの有効化
  - 各リクエストごとの TCP ハンドシェイク（SYN/SYN-ACK/ACK）を削減
  - HTTP/1.1 keep-alive による接続再利用を可能にする
  - Proxy オーバーヘッドを ~50-100ms 削減（推定）

これにより、Decode ノードが NIXL 経由で Prefill ノードの KV-Cache を直接取得し、
再 Prefill が不要になる。

Usage:
    python disagg_proxy_server.py \
        --prefill-url http://172.31.17.143:8100 \
        --decode-url http://172.31.25.231:8200 \
        --port 8000
"""

import argparse
import copy
import json
import logging
import time
from typing import AsyncGenerator

import aiohttp
from aiohttp import web

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class DisaggregatedProxyServerV2:
    def __init__(self, prefill_url: str, decode_url: str):
        self.prefill_url = prefill_url.rstrip('/')
        self.decode_url = decode_url.rstrip('/')
        self.session = None  # [P0-00] ClientSession をインスタンス変数として保持
        logger.info(
            "Initialized proxy v2: Prefill=%s, Decode=%s",
            self.prefill_url,
            self.decode_url,
        )

    async def start(self):
        """
        [P0-00] ClientSession を作成し、接続プーリングを有効化する。

        この修正により、各リクエストごとの TCP ハンドシェイク（SYN/SYN-ACK/ACK）を
        排除し、HTTP/1.1 の keep-alive による接続再利用を可能にする。
        """
        if self.session is None:
            self.session = aiohttp.ClientSession()
            logger.info("[Proxy] ClientSession created (connection pooling enabled)")

    async def cleanup(self):
        """
        [P0-00] ClientSession を適切に閉じる。
        """
        if self.session is not None:
            await self.session.close()
            self.session = None
            logger.info("[Proxy] ClientSession closed")

    async def run_prefill(self, request_data: dict) -> dict:
        """
        Prefill phase: max_tokens=1, kv_transfer_params={"do_remote_decode": true}

        Prefill ノードに KV-Cache を生成させ、そのブロック情報を含む
        kv_transfer_params をレスポンスから取得する。
        """
        prefill_data = copy.deepcopy(request_data)
        prefill_data["max_tokens"] = 1
        prefill_data["stream"] = False

        # KV-Cache 転送を有効化: Prefill ノードに「Decode ノードが後で KV-Cache を
        # 取得しにくる」ことを伝える。これにより NixlConnector が
        # request_finished_generating 時に kv_transfer_params を返す。
        prefill_data["kv_transfer_params"] = {"do_remote_decode": True}

        logger.info(
            "[Prefill] Sending request to %s/v1/completions "
            "(max_tokens=1, do_remote_decode=true)",
            self.prefill_url,
        )
        start_time = time.perf_counter()

        # [P0-00] 既存の self.session を再利用（TCP ハンドシェイクの削減）
        async with self.session.post(
            f"{self.prefill_url}/v1/completions",
            json=prefill_data,
            timeout=aiohttp.ClientTimeout(total=120),
        ) as response:
            if response.status != 200:
                error_text = await response.text()
                raise RuntimeError(
                    f"Prefill failed: {response.status} - {error_text}"
                )

            result = await response.json()
            prefill_time = time.perf_counter() - start_time

            # kv_transfer_params を取得
            kv_params = result.get("kv_transfer_params")
            logger.info(
                "[Prefill] Completed in %.2f ms, "
                "kv_transfer_params=%s",
                prefill_time * 1000,
                json.dumps(kv_params) if kv_params else "None",
            )

            if not kv_params:
                logger.warning(
                    "[Prefill] kv_transfer_params is empty! "
                    "KV-Cache transfer will NOT work. "
                    "Check that Prefill node is started with "
                    "--kv-transfer-config and kv_connector=NixlConnector"
                )

            return result

    async def stream_decode(
        self,
        request_data: dict,
        kv_transfer_params: dict | None,
    ) -> AsyncGenerator[bytes, None]:
        """
        Decode phase: kv_transfer_params from Prefill response

        Decode ノードに kv_transfer_params を渡すことで、NIXL 経由で
        Prefill ノードの KV-Cache を直接取得する。
        """
        decode_data = copy.deepcopy(request_data)
        decode_data["stream"] = True

        # Prefill レスポンスの kv_transfer_params を Decode リクエストに渡す
        if kv_transfer_params:
            decode_data["kv_transfer_params"] = kv_transfer_params
            logger.info(
                "[Decode] Sending request with kv_transfer_params "
                "(remote_engine_id=%s, remote_block_ids count=%d)",
                kv_transfer_params.get("remote_engine_id", "unknown"),
                len(kv_transfer_params.get("remote_block_ids", [])),
            )
        else:
            logger.warning(
                "[Decode] No kv_transfer_params available. "
                "Decode will do its own prefill (no KV-Cache transfer)."
            )

        logger.info(
            "[Decode] Sending streaming request to %s/v1/completions",
            self.decode_url,
        )
        start_time = time.perf_counter()

        # [P0-00] 既存の self.session を再利用（TCP ハンドシェイクの削減）
        async with self.session.post(
            f"{self.decode_url}/v1/completions",
            json=decode_data,
            timeout=aiohttp.ClientTimeout(total=300),
        ) as response:
            if response.status != 200:
                error_text = await response.text()
                raise RuntimeError(
                    f"Decode failed: {response.status} - {error_text}"
                )

            async for line in response.content:
                yield line

            decode_time = time.perf_counter() - start_time
            logger.info(
                "[Decode] Completed streaming in %.2f ms",
                decode_time * 1000,
            )

    async def handle_completion(self, request: web.Request) -> web.StreamResponse:
        """
        /v1/completions endpoint

        1. Prefill ノードに max_tokens=1 + do_remote_decode=true でリクエスト
        2. レスポンスから kv_transfer_params を取得
        3. Decode ノードに kv_transfer_params 付きでストリーミングリクエスト

        [P0-4] タイムスタンプを記録して HTTP ヘッダーに追加
        """
        try:
            # [P0-4] タイムスタンプ記録開始
            t0 = time.perf_counter()

            request_data = await request.json()
            request_id = f"proxy-{int(time.time() * 1000000)}"

            logger.info(
                "[Proxy] Received request: %s, model=%s, max_tokens=%s",
                request_id,
                request_data.get("model"),
                request_data.get("max_tokens", 16),
            )

            # Step 1: Prefill (KV-Cache generation with do_remote_decode)
            prefill_result = await self.run_prefill(request_data)
            t1 = time.perf_counter()

            # Step 2: Extract kv_transfer_params from Prefill response
            kv_transfer_params = prefill_result.get("kv_transfer_params")
            t2 = time.perf_counter()

            # タイミング計算
            timing = {
                "proxy_receive": t0,
                "prefill_complete": (t1 - t0) * 1000,  # ms
                "kv_extract": (t2 - t1) * 1000,  # ms
            }

            # Step 3: Decode (token generation with kv_transfer_params)
            if request_data.get("stream", False):
                response = web.StreamResponse()
                response.headers["Content-Type"] = "text/event-stream"
                response.headers["Cache-Control"] = "no-cache"
                response.headers["Connection"] = "keep-alive"

                # [P0-4] タイミング情報をヘッダーに追加
                response.headers["X-Proxy-Prefill-Time"] = f"{timing['prefill_complete']:.2f}"
                response.headers["X-Proxy-KV-Extract-Time"] = f"{timing['kv_extract']:.2f}"

                await response.prepare(request)

                # Decode の最初のチャンクまでの時間を測定
                first_chunk = True
                t3 = None
                async for chunk in self.stream_decode(
                    request_data, kv_transfer_params
                ):
                    if first_chunk:
                        t3 = time.perf_counter()
                        decode_first_token = (t3 - t2) * 1000
                        logger.info(
                            "[Proxy] Timing - Prefill: %.2f ms, KV Extract: %.2f ms, "
                            "Decode First Token: %.2f ms, Total: %.2f ms",
                            timing["prefill_complete"],
                            timing["kv_extract"],
                            decode_first_token,
                            (t3 - t0) * 1000,
                        )
                        first_chunk = False
                    await response.write(chunk)

                await response.write_eof()
                return response
            else:
                collected_chunks = []
                async for chunk in self.stream_decode(
                    request_data, kv_transfer_params
                ):
                    collected_chunks.append(chunk)

                final_result = self._extract_final_result(collected_chunks)
                return web.json_response(final_result)

        except Exception as e:
            logger.error("[Proxy] Error: %s", e, exc_info=True)
            return web.json_response(
                {"error": str(e)},
                status=500,
            )

    def _extract_final_result(self, chunks: list) -> dict:
        """
        Extract final result from SSE streaming chunks.
        """
        result = None
        for chunk in chunks:
            try:
                line = chunk.decode("utf-8").strip()
                if line.startswith("data: ") and line != "data: [DONE]":
                    result = json.loads(line[6:])
            except Exception:
                continue

        return result or {"error": "No valid response"}

    async def health_check(self, request: web.Request) -> web.Response:
        """
        Health check endpoint.
        """
        return web.json_response({
            "status": "healthy",
            "version": "v3",
            "prefill_url": self.prefill_url,
            "decode_url": self.decode_url,
            "features": [
                "kv_transfer_params_passthrough",
                "internal_timestamps",
                "connection_pooling"  # [P0-00]
            ],
        })


def main():
    parser = argparse.ArgumentParser(
        description="Disaggregated Prefill Proxy Server v3 (KV-Cache transfer + Connection pooling)"
    )
    parser.add_argument(
        "--prefill-url",
        type=str,
        default="http://172.31.17.143:8100",
        help="Prefill instance URL",
    )
    parser.add_argument(
        "--decode-url",
        type=str,
        default="http://172.31.25.231:8200",
        help="Decode instance URL",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8000,
        help="Proxy server port",
    )
    parser.add_argument(
        "--host",
        type=str,
        default="0.0.0.0",
        help="Proxy server host",
    )

    args = parser.parse_args()

    proxy = DisaggregatedProxyServerV2(args.prefill_url, args.decode_url)

    app = web.Application()
    app.router.add_post("/v1/completions", proxy.handle_completion)
    app.router.add_get("/health", proxy.health_check)

    # [P0-00] アプリケーション起動時/終了時のライフサイクル管理
    async def on_startup(app):
        await proxy.start()

    async def on_cleanup(app):
        await proxy.cleanup()

    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)

    logger.info(
        "Starting Disaggregated Proxy Server v3 on %s:%s",
        args.host,
        args.port,
    )
    logger.info("  Prefill URL: %s", args.prefill_url)
    logger.info("  Decode URL: %s", args.decode_url)
    logger.info("  KV-Cache transfer: ENABLED (kv_transfer_params passthrough)")
    logger.info("  [P0-00] Connection pooling: ENABLED (ClientSession reuse)")

    web.run_app(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
