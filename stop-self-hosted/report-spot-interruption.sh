#!/usr/bin/env bash
# Annotates the job when AWS reclaimed the runner's spot instance.
# retry-spot-interruption matches the annotation title.
set -euo pipefail

if ! code=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].StateReason.Code' \
    --output text); then
    echo "::warning::Could not determine why instance $INSTANCE_ID stopped."
    exit 0
fi

if [ "$code" = "Server.SpotInstanceTermination" ]; then
    echo "::error title=Spot instance reclaimed::AWS reclaimed spot instance $INSTANCE_ID while it was running this workflow."
fi
