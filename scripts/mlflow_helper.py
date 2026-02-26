"""
MLflow Helper - SageMaker Managed MLflow 接続ヘルパー

sagemaker-mlflow プラグインを使用して、ARN ベースの SigV4 認証で
SageMaker Managed MLflow に接続します。

必要なパッケージ:
  pip install sagemaker-mlflow

仕組み:
  sagemaker-mlflow プラグインは MLflow の entry_points に以下を登録します:
  - mlflow.tracking_store: "arn" -> MlflowSageMakerStore
  - mlflow.request_auth_provider: "arn" -> AuthProvider (SigV4)
  - mlflow.request_header_provider: "arn" -> MlflowSageMakerRequestHeaderProvider

  tracking URI に ARN を設定すると、プラグインが自動的に:
  1. ARN からリージョンとサーバー名を解析
  2. https://{region}.experiments.sagemaker.aws エンドポイントに接続
  3. 各リクエストに SigV4 認証ヘッダーを付与
  4. x-mlflow-sm-tracking-server-arn ヘッダーを追加
"""

import os
import sys
import logging
from typing import Optional

logger = logging.getLogger(__name__)


def _verify_plugin_installed() -> bool:
    """sagemaker-mlflow プラグインがインストールされているか確認する。

    Returns:
        True: プラグインが利用可能
        False: プラグインが見つからない
    """
    try:
        import sagemaker_mlflow  # noqa: F401
        return True
    except ImportError:
        return False


def _verify_entry_points() -> dict:
    """MLflow プラグインのエントリポイント登録状態を確認する。

    Returns:
        各エントリポイントグループの登録状態を示す辞書
    """
    import pkg_resources

    results = {}
    for group in [
        "mlflow.tracking_store",
        "mlflow.request_auth_provider",
        "mlflow.request_header_provider",
    ]:
        eps = list(pkg_resources.iter_entry_points(group))
        arn_eps = [ep for ep in eps if ep.name == "arn"]
        results[group] = len(arn_eps) > 0

    return results


def setup_mlflow_tracking(
    tracking_arn: Optional[str] = None,
) -> str:
    """SageMaker Managed MLflow の tracking を設定する。

    sagemaker-mlflow プラグインを使用して、ARN ベースの SigV4 認証で
    MLflow tracking server に接続します。presigned URL は不要です。

    Args:
        tracking_arn: MLflow tracking server の ARN。
            未指定の場合は MLFLOW_TRACKING_ARN 環境変数から取得。

    Returns:
        設定された tracking URI (= ARN)

    Raises:
        RuntimeError: ARN が未指定、プラグイン未インストール、
            または設定に失敗した場合
    """
    # --- 1. sagemaker-mlflow プラグインの確認 ---
    if not _verify_plugin_installed():
        raise RuntimeError(
            "sagemaker-mlflow プラグインがインストールされていません。\n"
            "以下のコマンドでインストールしてください:\n"
            "  pip install --user sagemaker-mlflow\n\n"
            "または install-mlflow-deps.sh を実行してください:\n"
            "  bash install-mlflow-deps.sh"
        )

    # --- 2. ARN の取得と検証 ---
    arn = tracking_arn or os.environ.get("MLFLOW_TRACKING_ARN")

    if not arn:
        raise RuntimeError(
            "MLflow tracking server ARN が指定されていません。\n"
            "以下のいずれかの方法で設定してください:\n"
            "  1. MLFLOW_TRACKING_ARN 環境変数を設定\n"
            "     export MLFLOW_TRACKING_ARN=arn:aws:sagemaker:<region>:<account>:mlflow-tracking-server/<name>\n"
            "  2. tracking_arn パラメータに ARN を渡す\n"
            "  3. source /etc/environment を実行（CDK デプロイ環境の場合）"
        )

    # ARN 形式の基本検証
    if not arn.startswith("arn:aws:sagemaker:"):
        raise RuntimeError(
            f"無効な ARN 形式です: {arn}\n"
            "正しい形式: arn:aws:sagemaker:<region>:<account>:mlflow-tracking-server/<name>"
        )

    parts = arn.split(":")
    if len(parts) < 6 or "/" not in parts[5]:
        raise RuntimeError(
            f"ARN の解析に失敗しました: {arn}\n"
            "正しい形式: arn:aws:sagemaker:<region>:<account>:mlflow-tracking-server/<name>"
        )

    region = parts[3]
    resource_type = parts[5].split("/")[0]
    resource_name = parts[5].split("/")[1]

    logger.info(f"MLflow tracking server: {resource_name} (region: {region})")

    # --- 3. エントリポイントの確認 ---
    ep_status = _verify_entry_points()
    missing = [k for k, v in ep_status.items() if not v]
    if missing:
        logger.warning(
            "以下のエントリポイントが未登録です: %s\n"
            "sagemaker-mlflow を再インストールしてください: "
            "pip install --user --force-reinstall sagemaker-mlflow",
            ", ".join(missing),
        )

    # --- 4. AWS 認証情報の確認 ---
    try:
        import boto3
        sts = boto3.client("sts", region_name=region)
        identity = sts.get_caller_identity()
        logger.info(f"AWS identity: {identity['Arn']}")
    except Exception as e:
        raise RuntimeError(
            f"AWS 認証情報の取得に失敗しました: {e}\n"
            "IAM ロールまたは AWS 認証情報が正しく設定されているか確認してください。"
        ) from e

    # --- 5. MLflow tracking URI の設定 ---
    # sagemaker-mlflow プラグインは tracking URI が ARN の場合に自動的に有効化されます。
    # プラグインが以下を処理します:
    #   - ARN -> エンドポイント URL の変換
    #   - SigV4 認証ヘッダーの生成
    #   - x-mlflow-sm-tracking-server-arn ヘッダーの追加
    import mlflow

    os.environ["MLFLOW_TRACKING_URI"] = arn
    mlflow.set_tracking_uri(arn)

    print(f"[INFO] MLflow tracking URI を設定しました")
    print(f"  Server:   {resource_name}")
    print(f"  Region:   {region}")
    print(f"  Type:     {resource_type}")
    print(f"  Auth:     SigV4 (sagemaker-mlflow plugin)")

    # --- 6. 接続テスト ---
    try:
        # experiments の一覧取得で接続を確認
        client = mlflow.MlflowClient()
        # search_experiments は軽量な API コール
        _ = client.search_experiments(max_results=1)
        print(f"  Status:   [OK] 接続成功")
    except Exception as e:
        error_msg = str(e)
        print(f"  Status:   [ERROR] 接続失敗")
        print(f"  Detail:   {error_msg}")

        # よくあるエラーのトラブルシューティング
        if "403" in error_msg or "Forbidden" in error_msg:
            print("\n[TROUBLESHOOTING] 403 エラーの原因:")
            print("  1. IAM ロールに sagemaker-mlflow:* 権限がない")
            print("  2. IAM ロールに sagemaker:DescribeMlflowTrackingServer 権限がない")
            print("  3. tracking server が別のリージョンにある")
            print("  4. tracking server 名が間違っている")
        elif "timeout" in error_msg.lower() or "connect" in error_msg.lower():
            print("\n[TROUBLESHOOTING] 接続タイムアウト:")
            print("  1. VPC からインターネットへの接続を確認")
            print("  2. セキュリティグループの outbound ルールを確認")

        raise RuntimeError(
            f"MLflow tracking server への接続に失敗しました: {e}"
        ) from e

    return arn


if __name__ == "__main__":
    # CLI 使用（テスト用）
    logging.basicConfig(level=logging.INFO)

    try:
        uri = setup_mlflow_tracking()
        print(f"\n[OK] MLflow tracking URI: {uri}")
    except Exception as e:
        print(f"\n[ERROR] {e}", file=sys.stderr)
        sys.exit(1)
