#!/bin/bash
# toxiproxy_setup.sh - Toxiproxy wrapper for chaos testing
# Provides network failure simulation without requiring iptables

set -euo pipefail

TOXIPROXY_CONTAINER="toxiproxy-s3sweep"
TOXIPROXY_API="http://localhost:8474"

# Start Toxiproxy container
start_toxiproxy() {
    if docker ps --format '{{.Names}}' | grep -q "^${TOXIPROXY_CONTAINER}$"; then
        echo "Toxiproxy already running"
        return 0
    fi

    echo "Starting Toxiproxy..."
    docker run -d --name "$TOXIPROXY_CONTAINER" \
        --network "$TEST_NETWORK" \
        -p 8474:8474 \
        -p 20000-20010:20000-20010 \
        ghcr.io/shopify/toxiproxy:latest

    # Wait for API to be ready
    for i in {1..30}; do
        if curl -sf "$TOXIPROXY_API/version" >/dev/null 2>&1; then
            echo "Toxiproxy ready"
            return 0
        fi
        sleep 0.5
    done

    echo "ERROR: Toxiproxy failed to start"
    return 1
}

# Stop and remove Toxiproxy container
stop_toxiproxy() {
    if docker ps -q -f name="$TOXIPROXY_CONTAINER" >/dev/null 2>&1; then
        echo "Stopping Toxiproxy..."
        docker stop "$TOXIPROXY_CONTAINER" >/dev/null 2>&1 || true
        docker rm "$TOXIPROXY_CONTAINER" >/dev/null 2>&1 || true
    fi
}

# Create a proxy
# Usage: create_proxy <name> <listen> <upstream>
# Example: create_proxy s3_proxy localhost:20000 s3_a:9000
create_proxy() {
    local name="$1"
    local listen="$2"
    local upstream="$3"

    echo "Creating proxy: $name ($listen -> $upstream)"
    curl -sf -X POST "$TOXIPROXY_API/proxies" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$name\",
            \"listen\": \"$listen\",
            \"upstream\": \"$upstream\",
            \"enabled\": true
        }" >/dev/null

    echo "Proxy $name created"
}

# Delete a proxy
delete_proxy() {
    local name="$1"
    echo "Deleting proxy: $name"
    curl -sf -X DELETE "$TOXIPROXY_API/proxies/$name" >/dev/null || true
}

# List all proxies
list_proxies() {
    curl -sf "$TOXIPROXY_API/proxies" | jq -r 'keys[]'
}

# Add latency toxic
# Usage: add_latency <proxy_name> <latency_ms> <jitter_ms>
# Example: add_latency s3_proxy 5000 1000
add_latency() {
    local proxy="$1"
    local latency="${2:-1000}"
    local jitter="${3:-0}"

    echo "Adding latency to $proxy: ${latency}ms ± ${jitter}ms"
    curl -sf -X POST "$TOXIPROXY_API/proxies/$proxy/toxics" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"latency_downstream\",
            \"type\": \"latency\",
            \"stream\": \"downstream\",
            \"toxicity\": 1.0,
            \"attributes\": {
                \"latency\": $latency,
                \"jitter\": $jitter
            }
        }" >/dev/null

    echo "Latency added"
}

# Add timeout toxic (closes connection after N ms)
# Usage: add_timeout <proxy_name> <timeout_ms>
add_timeout() {
    local proxy="$1"
    local timeout="${2:-0}"

    echo "Adding timeout to $proxy: ${timeout}ms"
    curl -sf -X POST "$TOXIPROXY_API/proxies/$proxy/toxics" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"timeout_downstream\",
            \"type\": \"timeout\",
            \"stream\": \"downstream\",
            \"toxicity\": 1.0,
            \"attributes\": {
                \"timeout\": $timeout
            }
        }" >/dev/null

    echo "Timeout added"
}

# Add bandwidth limit
# Usage: add_bandwidth_limit <proxy_name> <rate_kb_per_sec>
add_bandwidth_limit() {
    local proxy="$1"
    local rate="${2:-100}"  # KB/s

    echo "Adding bandwidth limit to $proxy: ${rate} KB/s"
    curl -sf -X POST "$TOXIPROXY_API/proxies/$proxy/toxics" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"bandwidth_downstream\",
            \"type\": \"bandwidth\",
            \"stream\": \"downstream\",
            \"toxicity\": 1.0,
            \"attributes\": {
                \"rate\": $rate
            }
        }" >/dev/null

    echo "Bandwidth limit added"
}

# Add packet loss
# Usage: add_packet_loss <proxy_name> <percentage>
add_packet_loss() {
    local proxy="$1"
    local percentage="${2:-50}"  # 0-100

    echo "Adding packet loss to $proxy: ${percentage}%"

    # Convert percentage to toxicity (0.0-1.0)
    local toxicity=$(echo "scale=2; $percentage / 100" | bc)

    curl -sf -X POST "$TOXIPROXY_API/proxies/$proxy/toxics" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"packet_loss_downstream\",
            \"type\": \"timeout\",
            \"stream\": \"downstream\",
            \"toxicity\": $toxicity,
            \"attributes\": {
                \"timeout\": 0
            }
        }" >/dev/null

    echo "Packet loss added"
}

# Add slicer toxic (randomly slices TCP packets)
add_slicer() {
    local proxy="$1"
    local avg_size="${2:-64}"
    local size_variation="${3:-32}"
    local delay="${4:-10}"

    echo "Adding slicer to $proxy"
    curl -sf -X POST "$TOXIPROXY_API/proxies/$proxy/toxics" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"slicer_downstream\",
            \"type\": \"slicer\",
            \"stream\": \"downstream\",
            \"toxicity\": 1.0,
            \"attributes\": {
                \"average_size\": $avg_size,
                \"size_variation\": $size_variation,
                \"delay\": $delay
            }
        }" >/dev/null

    echo "Slicer added"
}

# Remove all toxics from a proxy
# Usage: remove_toxics <proxy_name>
remove_toxics() {
    local proxy="$1"

    echo "Removing all toxics from $proxy"

    # Get list of toxic names
    local toxics
    toxics=$(curl -sf "$TOXIPROXY_API/proxies/$proxy/toxics" | jq -r '.[].name')

    for toxic in $toxics; do
        echo "  Removing toxic: $toxic"
        curl -sf -X DELETE "$TOXIPROXY_API/proxies/$proxy/toxics/$toxic" >/dev/null || true
    done

    echo "All toxics removed"
}

# Disable a proxy (stops forwarding traffic)
disable_proxy() {
    local proxy="$1"

    echo "Disabling proxy: $proxy"
    curl -sf -X POST "$TOXIPROXY_API/proxies/$proxy" \
        -H "Content-Type: application/json" \
        -d '{"enabled": false}' >/dev/null
}

# Enable a proxy
enable_proxy() {
    local proxy="$1"

    echo "Enabling proxy: $proxy"
    curl -sf -X POST "$TOXIPROXY_API/proxies/$proxy" \
        -H "Content-Type: application/json" \
        -d '{"enabled": true}' >/dev/null
}

# Get proxy status
get_proxy_status() {
    local proxy="$1"
    curl -sf "$TOXIPROXY_API/proxies/$proxy" | jq '.'
}

# Reset Toxiproxy (remove all proxies)
reset_toxiproxy() {
    echo "Resetting Toxiproxy..."
    curl -sf -X POST "$TOXIPROXY_API/reset" >/dev/null
    echo "Toxiproxy reset"
}

# Cleanup function for trap
cleanup_toxiproxy() {
    reset_toxiproxy 2>/dev/null || true
}

# Export functions
export -f start_toxiproxy
export -f stop_toxiproxy
export -f create_proxy
export -f delete_proxy
export -f list_proxies
export -f add_latency
export -f add_timeout
export -f add_bandwidth_limit
export -f add_packet_loss
export -f add_slicer
export -f remove_toxics
export -f disable_proxy
export -f enable_proxy
export -f get_proxy_status
export -f reset_toxiproxy
export -f cleanup_toxiproxy
