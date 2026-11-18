#!/usr/bin/env bash
# Stops the container build when AWS announces that this spot instance will be reclaimed.
# Usage: spot-interruption-watcher.sh <marker-file>
set -uo pipefail

marker=$1
imds=http://169.254.169.254/latest

while true; do
    token=$(curl -fsS -m 2 -X PUT "$imds/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 300") || token=""

    if [ -n "$token" ] && curl -fsS -m 2 -o /dev/null \
        -H "X-aws-ec2-metadata-token: $token" \
        "$imds/meta-data/spot/instance-action"; then
        touch "$marker"
        docker ps -q | xargs -r docker kill
        pkill -f "buildx build"
        exit 0
    fi

    sleep 5
done
