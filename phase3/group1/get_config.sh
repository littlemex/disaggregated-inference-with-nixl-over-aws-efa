#!/bin/bash
# Phase 3 Group 1 Configuration Helper
# Usage: source get_config.sh

# Load configuration from JSON
CONFIG_FILE="$(dirname "$BASH_SOURCE")/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE" >&2
    return 1
fi

# Export environment variables
export REPO_PATH=$(jq -r '.repository.path' "$CONFIG_FILE")
export PRODUCER_PUBLIC_IP=$(jq -r '.nodes.producer.public_ip' "$CONFIG_FILE")
export PRODUCER_PRIVATE_IP=$(jq -r '.nodes.producer.private_ip' "$CONFIG_FILE")
export PRODUCER_PORT=$(jq -r '.nodes.producer.port' "$CONFIG_FILE")
export CONSUMER_PUBLIC_IP=$(jq -r '.nodes.consumer.public_ip' "$CONFIG_FILE")
export CONSUMER_PRIVATE_IP=$(jq -r '.nodes.consumer.private_ip' "$CONFIG_FILE")
export CONSUMER_PORT=$(jq -r '.nodes.consumer.port' "$CONFIG_FILE")
export ZMQ_PORT=$(jq -r '.networking.zmq_port' "$CONFIG_FILE")
export KV_PORT=$(jq -r '.networking.kv_port' "$CONFIG_FILE")
export SSH_KEY=$(jq -r '.ssh.key_path' "$CONFIG_FILE")
export SSH_USER=$(jq -r '.ssh.user' "$CONFIG_FILE")
export AWS_REGION=$(jq -r '.networking.region' "$CONFIG_FILE")
export NIXL_LOG_LEVEL=$(jq -r '.logging.nixl_log_level' "$CONFIG_FILE")
export VLLM_LOGGING_LEVEL=$(jq -r '.logging.vllm_logging_level' "$CONFIG_FILE")

# Helper functions
ssh_producer() {
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$PRODUCER_PUBLIC_IP" "$@"
}

ssh_consumer() {
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$CONSUMER_PUBLIC_IP" "$@"
}

curl_producer() {
    curl -s "http://$PRODUCER_PUBLIC_IP:$PRODUCER_PORT$1"
}

curl_consumer() {
    curl -s "http://$CONSUMER_PUBLIC_IP:$CONSUMER_PORT$1"
}

# Display loaded configuration
echo "Loaded Phase 3 Group 1 Configuration:"
echo "  Repository: $REPO_PATH"
echo "  Producer:   $PRODUCER_PUBLIC_IP (private: $PRODUCER_PRIVATE_IP) port $PRODUCER_PORT"
echo "  Consumer:   $CONSUMER_PUBLIC_IP (private: $CONSUMER_PRIVATE_IP) port $CONSUMER_PORT"
echo "  ZMQ Port:   $ZMQ_PORT"
echo "  KV Port:    $KV_PORT"
echo ""
echo "Helper functions available:"
echo "  ssh_producer <command>"
echo "  ssh_consumer <command>"
echo "  curl_producer <path>"
echo "  curl_consumer <path>"
