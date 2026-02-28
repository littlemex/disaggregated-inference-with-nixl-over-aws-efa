#!/bin/bash

set -e

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================================================================${NC}"
echo -e "${BLUE}MLflow 接続確認スクリプト${NC}"
echo -e "${BLUE}================================================================================${NC}"
echo ""

# 環境変数の設定
MLFLOW_TRACKING_ARN="${MLFLOW_TRACKING_ARN:-arn:aws:sagemaker:us-east-1:776010787911:mlflow-tracking-server/mlflow-tracking-server}"
REGION="us-east-1"
EXPERIMENT_NAME="${EXPERIMENT_NAME:-nixl-efa-test}"

echo -e "${YELLOW}[設定]${NC}"
echo "  Tracking ARN: $MLFLOW_TRACKING_ARN"
echo "  Region: $REGION"
echo "  Experiment: $EXPERIMENT_NAME"
echo ""

# ==================================================================================
# STEP 1: Presigned URL の生成
# ==================================================================================
echo -e "${YELLOW}[STEP 1] Presigned URL の生成${NC}"
TRACKING_SERVER_NAME=$(echo "$MLFLOW_TRACKING_ARN" | awk -F'/' '{print $NF}')
PRESIGNED_URL=$(aws sagemaker create-presigned-mlflow-tracking-server-url \
    --tracking-server-name "$TRACKING_SERVER_NAME" \
    --region "$REGION" \
    --session-expiration-duration-in-seconds 43200 \
    --query 'AuthorizedUrl' \
    --output text)

if [ -n "$PRESIGNED_URL" ]; then
    echo -e "  ${GREEN}[OK]${NC} Presigned URL を生成しました"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}MLflow Web UI にアクセス:${NC}"
    echo ""
    echo -e "${BLUE}$PRESIGNED_URL${NC}"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}有効期限:${NC} 12時間"
    echo ""
else
    echo -e "  ${RED}[ERROR]${NC} Presigned URL の生成に失敗しました"
    exit 1
fi

# ==================================================================================
# STEP 2: MLflow Python API で実験データを取得
# ==================================================================================
echo -e "${YELLOW}[STEP 2] MLflow API で実験データを取得${NC}"

# Python が利用可能か確認
if ! command -v python3 &> /dev/null; then
    echo -e "  ${RED}[ERROR]${NC} python3 が見つかりません"
    exit 1
fi

# MLflow パッケージが利用可能か確認
if ! python3 -c "import mlflow" 2>/dev/null; then
    echo -e "  ${RED}[ERROR]${NC} mlflow パッケージがインストールされていません"
    echo "  インストール: pip install mlflow sagemaker-mlflow"
    exit 1
fi

# Python スクリプトで MLflow API にアクセス
python3 << PYTHON_EOF
import os
import sys
import mlflow
from mlflow.tracking import MlflowClient
from datetime import datetime

# MLflow の設定
mlflow_arn = os.environ.get("MLFLOW_TRACKING_ARN", "arn:aws:sagemaker:us-east-1:776010787911:mlflow-tracking-server/mlflow-tracking-server")
experiment_name = os.environ.get("EXPERIMENT_NAME", "nixl-efa-test")

print(f"  Tracking URI: {mlflow_arn}")
print(f"  Experiment: {experiment_name}")
print("")

try:
    mlflow.set_tracking_uri(mlflow_arn)
    client = MlflowClient()

    # Experiment の取得
    experiment = mlflow.get_experiment_by_name(experiment_name)

    if not experiment:
        print(f"  ⚠ Experiment '{experiment_name}' が見つかりませんでした")
        sys.exit(0)

    print(f"  ✓ Experiment 取得成功:")
    print(f"    - ID: {experiment.experiment_id}")
    print(f"    - Name: {experiment.name}")
    print(f"    - Artifact Location: {experiment.artifact_location}")
    print("")

    # 最新の Run を取得
    runs = client.search_runs(
        experiment_ids=[experiment.experiment_id],
        order_by=["start_time DESC"],
        max_results=5
    )

    if not runs:
        print("  ⚠ Run が見つかりませんでした")
        sys.exit(0)

    print(f"  ✓ Run を {len(runs)} 件取得しました:")
    print("")

    for i, run in enumerate(runs, 1):
        run_name = run.data.tags.get('mlflow.runName', 'N/A')
        start_time = datetime.fromtimestamp(run.info.start_time / 1000.0).strftime('%Y-%m-%d %H:%M:%S')

        print(f"  [{i}] Run ID: {run.info.run_id}")
        print(f"      Name: {run_name}")
        print(f"      Status: {run.info.status}")
        print(f"      Start Time: {start_time}")

        # Parameters
        if run.data.params:
            print(f"      Parameters ({len(run.data.params)}):")
            for key, value in sorted(run.data.params.items())[:5]:  # 最初の5個のみ表示
                print(f"        - {key}: {value}")
            if len(run.data.params) > 5:
                print(f"        ... 他 {len(run.data.params) - 5} 個")

        # Metrics
        if run.data.metrics:
            print(f"      Metrics ({len(run.data.metrics)}):")
            for key, value in sorted(run.data.metrics.items())[:5]:  # 最初の5個のみ表示
                print(f"        - {key}: {value:.4f}")
            if len(run.data.metrics) > 5:
                print(f"        ... 他 {len(run.data.metrics) - 5} 個")

        print("")

    print("  " + "─" * 60)
    print("")

except Exception as e:
    print(f"  ✗ エラー: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

PYTHON_EOF

# ==================================================================================
# 完了
# ==================================================================================
echo ""
echo -e "${GREEN}[完了] MLflow への接続確認が成功しました${NC}"
echo ""
echo -e "${YELLOW}[次のステップ]${NC}"
echo "  1. 上記の Presigned URL をブラウザで開いて Web UI を確認"
echo "  2. Run の詳細を確認（Parameters, Metrics, Artifacts）"
echo ""
