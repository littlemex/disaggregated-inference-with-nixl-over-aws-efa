"""
MLflow Helper - Presigned URL management for SageMaker Managed MLflow

This module provides helper functions to obtain presigned URLs for SageMaker
Managed MLflow tracking servers and initialize MLflow clients.
"""

import os
import sys
import json
import subprocess
from typing import Optional


def get_presigned_mlflow_url(
    tracking_arn: Optional[str] = None,
    session_expiration_duration: int = 43200  # 12 hours in seconds
) -> str:
    """
    Obtain a presigned URL for SageMaker Managed MLflow tracking server.

    Args:
        tracking_arn: MLflow tracking server ARN. If None, reads from MLFLOW_TRACKING_ARN env var.
        session_expiration_duration: Session expiration in seconds (max 43200 = 12 hours)

    Returns:
        Presigned MLflow tracking URL

    Raises:
        RuntimeError: If ARN is not provided or AWS CLI command fails
    """
    # Get ARN from parameter or environment variable
    arn = tracking_arn or os.environ.get("MLFLOW_TRACKING_ARN")

    if not arn:
        raise RuntimeError(
            "MLflow tracking server ARN not provided. "
            "Set MLFLOW_TRACKING_ARN environment variable or pass tracking_arn parameter."
        )

    # Parse ARN to extract tracking server name
    # ARN format: arn:aws:sagemaker:{region}:{account}:mlflow-tracking-server/{name}
    try:
        tracking_server_name = arn.split("/")[-1]
    except (IndexError, AttributeError):
        raise RuntimeError(f"Invalid MLflow tracking server ARN format: {arn}")

    # Execute AWS CLI command to get presigned URL
    cmd = [
        "aws", "sagemaker", "create-presigned-mlflow-tracking-server-url",
        "--tracking-server-name", tracking_server_name,
        "--session-expiration-duration-in-seconds", str(session_expiration_duration),
        "--output", "json"
    ]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=True
        )

        response = json.loads(result.stdout)
        presigned_url = response.get("AuthorizedUrl")

        if not presigned_url:
            raise RuntimeError(f"No AuthorizedUrl in response: {result.stdout}")

        return presigned_url

    except subprocess.CalledProcessError as e:
        raise RuntimeError(
            f"Failed to get presigned MLflow URL: {e.stderr}"
        ) from e
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"Failed to parse AWS CLI response: {result.stdout}"
        ) from e


def setup_mlflow_tracking(
    tracking_arn: Optional[str] = None,
    session_expiration_duration: int = 43200
) -> str:
    """
    Setup MLflow tracking by obtaining presigned URL and setting environment variable.

    Args:
        tracking_arn: MLflow tracking server ARN. If None, reads from MLFLOW_TRACKING_ARN env var.
        session_expiration_duration: Session expiration in seconds (max 43200 = 12 hours)

    Returns:
        Presigned MLflow tracking URL

    Side Effects:
        Sets MLFLOW_TRACKING_URI environment variable
    """
    import mlflow

    # Get presigned URL
    presigned_url = get_presigned_mlflow_url(tracking_arn, session_expiration_duration)

    # Set MLflow tracking URI
    os.environ["MLFLOW_TRACKING_URI"] = presigned_url
    mlflow.set_tracking_uri(presigned_url)

    print(f"[INFO] MLflow tracking URI configured (valid for {session_expiration_duration/3600:.1f} hours)")

    return presigned_url


if __name__ == "__main__":
    # CLI usage for testing
    try:
        url = get_presigned_mlflow_url()
        print(f"Presigned MLflow URL: {url}")
    except Exception as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        sys.exit(1)
