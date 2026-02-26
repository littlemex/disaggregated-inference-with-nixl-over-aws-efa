#!/usr/bin/env python3
"""
MLflow Test Script - Verify MLflow connectivity and basic operations

This script verifies that MLflow tracking server is accessible and working
correctly by performing basic create/read operations.
"""

import os
import sys
import argparse
from datetime import datetime

import mlflow
from mlflow_helper import setup_mlflow_tracking


def test_mlflow_connectivity(experiment_name: str = "nixl-efa-test") -> bool:
    """
    Test MLflow connectivity and basic operations.

    Args:
        experiment_name: Name of the experiment to use for testing

    Returns:
        True if all tests passed, False otherwise
    """
    print("\n" + "="*80)
    print("MLflow Connectivity Test")
    print("="*80)

    try:
        # Setup MLflow tracking (sagemaker-mlflow plugin handles SigV4 auth)
        print("\n[STEP 1] Setting up MLflow tracking...")
        tracking_uri = setup_mlflow_tracking()
        print(f"  Tracking URI (ARN): {tracking_uri}")

        # Create or get experiment
        print(f"\n[STEP 2] Creating/getting experiment: {experiment_name}")
        experiment = mlflow.set_experiment(experiment_name)
        print(f"  Experiment ID: {experiment.experiment_id}")
        print(f"  Artifact Location: {experiment.artifact_location}")

        # Start a test run
        print("\n[STEP 3] Starting test run...")
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        run_name = f"connectivity_test_{timestamp}"

        with mlflow.start_run(run_name=run_name) as run:
            run_id = run.info.run_id
            print(f"  Run ID: {run_id}")

            # Log parameters (using phase14-compatible schema)
            print("\n[STEP 4] Logging parameters...")
            test_params = {
                "backend": "tcp",
                "prompt_tokens": 128,
                "max_tokens": 128,
                "concurrency": 1,
                "engine": "vllm",
                "model": "test-model",
                "test_type": "connectivity",
            }

            for key, value in test_params.items():
                mlflow.log_param(key, value)
                print(f"  - {key}: {value}")

            # Log metrics (using phase14-compatible schema)
            print("\n[STEP 5] Logging metrics...")
            test_metrics = {
                "ttft_mean": 100.5,
                "ttft_p50": 98.2,
                "ttft_p95": 120.3,
                "ttft_p99": 145.7,
                "tpot_mean": 10.2,
                "tpot_p50": 9.8,
                "throughput_tokens_per_sec": 500.0,
            }

            for key, value in test_metrics.items():
                mlflow.log_metric(key, value)
                print(f"  - {key}: {value}")

            # Log tags
            print("\n[STEP 6] Logging tags...")
            mlflow.set_tags({
                "phase": "blog-01",
                "test": "connectivity",
                "timestamp": timestamp,
            })

        # Retrieve and verify the run
        print("\n[STEP 7] Retrieving and verifying run...")
        client = mlflow.tracking.MlflowClient()
        retrieved_run = client.get_run(run_id)

        # Verify parameters
        print("  Verifying parameters...")
        for key, expected_value in test_params.items():
            actual_value = retrieved_run.data.params.get(key)
            if str(actual_value) != str(expected_value):
                print(f"    [ERROR] Parameter mismatch: {key}")
                print(f"            Expected: {expected_value}")
                print(f"            Actual: {actual_value}")
                return False
        print("    [OK] All parameters verified")

        # Verify metrics
        print("  Verifying metrics...")
        for key, expected_value in test_metrics.items():
            actual_value = retrieved_run.data.metrics.get(key)
            if actual_value is None or abs(actual_value - expected_value) > 0.01:
                print(f"    [ERROR] Metric mismatch: {key}")
                print(f"            Expected: {expected_value}")
                print(f"            Actual: {actual_value}")
                return False
        print("    [OK] All metrics verified")

        # List recent runs
        print(f"\n[STEP 8] Listing recent runs in experiment...")
        runs = client.search_runs(
            experiment_ids=[experiment.experiment_id],
            order_by=["start_time DESC"],
            max_results=5
        )
        print(f"  Found {len(runs)} recent run(s):")
        for i, r in enumerate(runs, 1):
            print(f"    {i}. Run ID: {r.info.run_id}")
            print(f"       Name: {r.data.tags.get('mlflow.runName', 'N/A')}")
            print(f"       Status: {r.info.status}")
            print(f"       Start Time: {datetime.fromtimestamp(r.info.start_time/1000)}")

        print("\n" + "="*80)
        print("[SUCCESS] All MLflow connectivity tests passed!")
        print("="*80)
        return True

    except Exception as e:
        print("\n" + "="*80)
        print(f"[ERROR] MLflow connectivity test failed: {e}")
        print("="*80)
        import traceback
        traceback.print_exc()
        return False


def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description="Test MLflow connectivity and basic operations"
    )
    parser.add_argument(
        "--experiment-name",
        type=str,
        default="nixl-efa-test",
        help="MLflow experiment name for testing (default: nixl-efa-test)"
    )

    args = parser.parse_args()

    # Run test
    success = test_mlflow_connectivity(args.experiment_name)

    # Exit with appropriate code
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
