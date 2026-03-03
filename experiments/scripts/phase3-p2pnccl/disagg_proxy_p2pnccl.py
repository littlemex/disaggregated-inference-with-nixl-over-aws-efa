#!/usr/bin/env python3
"""
Disaggregated Prefill Proxy Server for P2pNcclConnector

P2pNcclConnector requires special request ID formatting:
- Prefill: request_id must contain ___decode_addr_<ip>:<port>
- Decode: request_id must contain ___prefill_addr_<ip>:<port>___

This proxy injects the peer ZMQ addresses into request IDs
so P2pNcclConnector can establish NCCL connections for KV transfer.
"""

import argparse
import copy
import json
import logging
import time
import uuid
from urllib.parse import urlparse

import aiohttp
from aiohttp import web

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class P2pNcclProxyServer:
    def __init__(self, prefill_url: str, decode_url: str,
                 prefill_zmq_port: int = 14579,
                 decode_zmq_port: int = 14579):
        self.prefill_url = prefill_url.rstrip('/')
        self.decode_url = decode_url.rstrip('/')
        self.session = None

        # Extract IPs from URLs
        self.prefill_ip = urlparse(prefill_url).hostname
        self.decode_ip = urlparse(decode_url).hostname

        # ZMQ ports (P2pNcclEngine binds to kv_port + rank_offset)
        self.prefill_zmq_port = prefill_zmq_port
        self.decode_zmq_port = decode_zmq_port

        logger.info(
            "Initialized P2pNccl proxy: Prefill=%s (ZMQ %s:%d), "
            "Decode=%s (ZMQ %s:%d)",
            self.prefill_url, self.prefill_ip, self.prefill_zmq_port,
            self.decode_url, self.decode_ip, self.decode_zmq_port,
        )

    async def start(self):
        if self.session is None:
            self.session = aiohttp.ClientSession()
            logger.info("[Proxy] ClientSession created")

    async def cleanup(self):
        if self.session is not None:
            await self.session.close()
            self.session = None

    def make_request_id(self):
        """Generate request ID with both prefill and decode addresses."""
        base_id = f"chatcmpl-{uuid.uuid4().hex[:16]}"
        # Embed both addresses so both sides can parse their peer
        request_id = (
            f"{base_id}"
            f"___prefill_addr_{self.prefill_ip}:{self.prefill_zmq_port}___"
            f"___decode_addr_{self.decode_ip}:{self.decode_zmq_port}"
        )
        return request_id

    async def handle_chat_completions(self, request: web.Request):
        """Handle /v1/chat/completions - the main disaggregated flow.

        P2pNcclConnector requires both Prefill and Decode requests to be
        sent simultaneously because NCCL send/recv must happen concurrently.
        The proxy sends both requests in parallel using asyncio.gather().
        """
        try:
            request_data = await request.json()
        except Exception as e:
            return web.json_response(
                {"error": {"message": f"Invalid JSON: {e}"}},
                status=400
            )

        stream = request_data.get("stream", False)
        original_max_tokens = request_data.get("max_tokens", 128)

        # Generate request ID with embedded addresses
        request_id = self.make_request_id()
        logger.info("[Request] %s stream=%s max_tokens=%d",
                     request_id, stream, original_max_tokens)

        t0 = time.perf_counter()

        # Prefill data: max_tokens=1 to just do prefill
        prefill_data = copy.deepcopy(request_data)
        prefill_data["max_tokens"] = 1
        prefill_data["stream"] = False

        # Decode data: full generation
        decode_data = copy.deepcopy(request_data)
        decode_data["max_tokens"] = original_max_tokens
        decode_data["stream"] = False

        # Send BOTH requests simultaneously - P2pNccl requires concurrent
        # send/recv, so Prefill and Decode must run in parallel
        import asyncio

        async def do_prefill():
            async with self.session.post(
                f"{self.prefill_url}/v1/chat/completions",
                json=prefill_data,
                headers={"X-Request-Id": request_id},
            ) as resp:
                result = await resp.json()
                t1 = time.perf_counter()
                logger.info("[Prefill] Completed in %.2fms (status=%d)",
                             (t1 - t0) * 1000, resp.status)
                return resp.status, result

        async def do_decode():
            async with self.session.post(
                f"{self.decode_url}/v1/chat/completions",
                json=decode_data,
                headers={"X-Request-Id": request_id},
            ) as resp:
                result = await resp.json()
                t2 = time.perf_counter()
                logger.info("[Decode] Completed in %.2fms (status=%d)",
                             (t2 - t0) * 1000, resp.status)
                return resp.status, result

        try:
            (prefill_status, prefill_result), (decode_status, decode_result) = \
                await asyncio.gather(do_prefill(), do_decode())
        except Exception as e:
            logger.error("[Request] Failed: %s", e)
            return web.json_response(
                {"error": {"message": f"Request failed: {e}"}},
                status=502
            )

        t_end = time.perf_counter()
        logger.info("[Request] Total %.2fms", (t_end - t0) * 1000)

        # Return the decode result (the actual generation)
        if decode_status != 200:
            logger.error("[Decode] Error: %s", decode_result)
        return web.json_response(decode_result, status=decode_status)

    async def handle_completions(self, request: web.Request):
        """Handle /v1/completions - same parallel flow for text completions."""
        try:
            request_data = await request.json()
        except Exception as e:
            return web.json_response(
                {"error": {"message": f"Invalid JSON: {e}"}},
                status=400
            )

        original_max_tokens = request_data.get("max_tokens", 128)

        request_id = self.make_request_id()
        logger.info("[Request-completions] %s max_tokens=%d",
                     request_id, original_max_tokens)

        t0 = time.perf_counter()

        prefill_data = copy.deepcopy(request_data)
        prefill_data["max_tokens"] = 1
        prefill_data["stream"] = False

        decode_data = copy.deepcopy(request_data)
        decode_data["max_tokens"] = original_max_tokens
        decode_data["stream"] = False

        import asyncio

        async def do_prefill():
            async with self.session.post(
                f"{self.prefill_url}/v1/completions",
                json=prefill_data,
                headers={"X-Request-Id": request_id},
            ) as resp:
                result = await resp.json()
                t1 = time.perf_counter()
                logger.info("[Prefill-completions] %.2fms (status=%d)",
                             (t1 - t0) * 1000, resp.status)
                return resp.status, result

        async def do_decode():
            async with self.session.post(
                f"{self.decode_url}/v1/completions",
                json=decode_data,
                headers={"X-Request-Id": request_id},
            ) as resp:
                result = await resp.json()
                t2 = time.perf_counter()
                logger.info("[Decode-completions] %.2fms (status=%d)",
                             (t2 - t0) * 1000, resp.status)
                return resp.status, result

        try:
            (prefill_status, prefill_result), (decode_status, decode_result) = \
                await asyncio.gather(do_prefill(), do_decode())
        except Exception as e:
            logger.error("[Request-completions] Failed: %s", e)
            return web.json_response(
                {"error": {"message": f"Request failed: {e}"}},
                status=502
            )

        t_end = time.perf_counter()
        logger.info("[Request-completions] Total %.2fms", (t_end - t0) * 1000)

        return web.json_response(decode_result, status=decode_status)

    async def handle_health(self, request: web.Request):
        """Health check."""
        checks = {}
        for name, url in [("prefill", self.prefill_url),
                          ("decode", self.decode_url)]:
            try:
                async with self.session.get(f"{url}/health") as resp:
                    checks[name] = "healthy" if resp.status == 200 else "unhealthy"
            except Exception:
                checks[name] = "unreachable"

        all_healthy = all(v == "healthy" for v in checks.values())
        return web.json_response(
            {"status": "healthy" if all_healthy else "degraded", **checks},
            status=200 if all_healthy else 503
        )


async def on_startup(app):
    await app["proxy"].start()


async def on_cleanup(app):
    await app["proxy"].cleanup()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefill-url", required=True)
    parser.add_argument("--decode-url", required=True)
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--prefill-zmq-port", type=int, default=14579)
    parser.add_argument("--decode-zmq-port", type=int, default=14579)
    args = parser.parse_args()

    proxy = P2pNcclProxyServer(
        args.prefill_url, args.decode_url,
        args.prefill_zmq_port, args.decode_zmq_port,
    )

    app = web.Application()
    app["proxy"] = proxy
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)

    app.router.add_get("/health", proxy.handle_health)
    app.router.add_post("/v1/chat/completions", proxy.handle_chat_completions)
    app.router.add_post("/v1/completions", proxy.handle_completions)

    logger.info("Starting P2pNccl Proxy on port %d", args.port)
    web.run_app(app, host="0.0.0.0", port=args.port)


if __name__ == "__main__":
    main()
