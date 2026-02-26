#!/usr/bin/env bash
# install-mlflow-deps.sh - SageMaker Managed MLflow 接続に必要なパッケージのインストール
#
# 使用方法:
#   bash install-mlflow-deps.sh
#
# 前提条件:
#   - Python 3.8 以上
#   - pip が利用可能
#   - AWS 認証情報が設定済み（IAM ロール or 環境変数）
#   - MLFLOW_TRACKING_ARN 環境変数が設定済み

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo "SageMaker Managed MLflow 依存パッケージインストール"
echo "============================================"
echo ""

# -------------------------------------------------------------------
# 1. Python バージョン確認
# -------------------------------------------------------------------
echo "[STEP 1] Python バージョン確認..."
PYTHON_VERSION=$(python3 --version 2>&1)
echo "  ${PYTHON_VERSION}"

PYTHON_MINOR=$(python3 -c "import sys; print(sys.version_info.minor)")
if [ "${PYTHON_MINOR}" -lt 8 ]; then
    echo "[ERROR] Python 3.8 以上が必要です"
    exit 1
fi
echo "  [OK] Python バージョン要件を満たしています"
echo ""

# -------------------------------------------------------------------
# 2. sagemaker-mlflow プラグインのインストール
# -------------------------------------------------------------------
echo "[STEP 2] sagemaker-mlflow プラグインのインストール..."
echo "  このプラグインが SigV4 認証と ARN ベースの接続を自動処理します"
pip install --user "sagemaker-mlflow>=0.1.0" 2>&1 | tail -5
echo "  [OK] sagemaker-mlflow インストール完了"
echo ""

# -------------------------------------------------------------------
# 3. インストール済みバージョンの確認
# -------------------------------------------------------------------
echo "[STEP 3] インストール済みパッケージの確認..."
echo ""

echo "  mlflow:"
python3 -c "import mlflow; print(f'    version = {mlflow.__version__}')" 2>&1 || {
    echo "    [ERROR] mlflow がインポートできません"
    exit 1
}

echo "  boto3:"
python3 -c "import boto3; print(f'    version = {boto3.__version__}')" 2>&1 || {
    echo "    [ERROR] boto3 がインポートできません"
    exit 1
}

echo "  sagemaker_mlflow:"
python3 -c "import sagemaker_mlflow; print('    [OK] インポート成功')" 2>&1 || {
    echo "    [ERROR] sagemaker_mlflow がインポートできません"
    exit 1
}

echo "  botocore (SigV4Auth):"
python3 -c "from botocore.auth import SigV4Auth; print('    [OK] SigV4Auth 利用可能')" 2>&1 || {
    echo "    [ERROR] botocore.auth.SigV4Auth がインポートできません"
    exit 1
}

echo ""

# -------------------------------------------------------------------
# 4. MLflow プラグインの登録確認
# -------------------------------------------------------------------
echo "[STEP 4] MLflow プラグイン登録の確認..."

python3 << 'PYEOF'
import pkg_resources

entry_points_to_check = [
    "mlflow.tracking_store",
    "mlflow.request_auth_provider",
    "mlflow.request_header_provider",
]

all_ok = True
for ep_group in entry_points_to_check:
    eps = list(pkg_resources.iter_entry_points(ep_group))
    arn_eps = [ep for ep in eps if ep.name == "arn"]
    if arn_eps:
        print(f"  {ep_group}: [OK] arn={arn_eps[0]}")
    else:
        print(f"  {ep_group}: [NG] 'arn' エントリポイントが見つかりません")
        all_ok = False

if not all_ok:
    print("\n  [WARNING] 一部のエントリポイントが登録されていません")
    print("  sagemaker-mlflow を再インストールしてください:")
    print("    pip install --user --force-reinstall sagemaker-mlflow")
    exit(1)
else:
    print("\n  [OK] 全エントリポイントが正常に登録されています")
PYEOF

echo ""

# -------------------------------------------------------------------
# 5. AWS 認証情報の確認
# -------------------------------------------------------------------
echo "[STEP 5] AWS 認証情報の確認..."

python3 << 'PYEOF'
import boto3

try:
    sts = boto3.client("sts")
    identity = sts.get_caller_identity()
    print(f"  Account:  {identity['Account']}")
    print(f"  Arn:      {identity['Arn']}")
    print(f"  UserId:   {identity['UserId']}")
    print("  [OK] AWS 認証情報が有効です")
except Exception as e:
    print(f"  [ERROR] AWS 認証情報の取得に失敗: {e}")
    exit(1)
PYEOF

echo ""

# -------------------------------------------------------------------
# 6. MLFLOW_TRACKING_ARN の確認
# -------------------------------------------------------------------
echo "[STEP 6] MLFLOW_TRACKING_ARN 環境変数の確認..."

if [ -z "${MLFLOW_TRACKING_ARN:-}" ]; then
    echo "  [WARNING] MLFLOW_TRACKING_ARN が設定されていません"
    echo "  以下のコマンドで設定してください:"
    echo "    export MLFLOW_TRACKING_ARN=arn:aws:sagemaker:<region>:<account>:mlflow-tracking-server/<name>"
    echo ""
    echo "  /etc/environment に定義されている場合は:"
    echo "    source /etc/environment"
else
    echo "  MLFLOW_TRACKING_ARN=${MLFLOW_TRACKING_ARN}"
    echo "  [OK] 環境変数が設定されています"
fi

echo ""
echo "============================================"
echo "[OK] インストール完了"
echo "============================================"
echo ""
echo "次のステップ:"
echo "  1. MLFLOW_TRACKING_ARN を環境変数に設定"
echo "  2. python3 test-mlflow.py で接続テストを実行"
echo ""
