#!/usr/bin/env bash
# Re-runs every job of a first-attempt run that failed because its spot runner was reclaimed.
# All jobs must re-run: the setup job has to start a replacement runner.
set -euo pipefail

if [ "$RUN_CONCLUSION" != "failure" ] || [ "$RUN_ATTEMPT" != "1" ]; then
    echo "Run $RUN_ID is not a failed first attempt."
    exit 0
fi

# Re-running a superseded run would deploy an older commit over a newer one.
latest_run=$(gh run list \
    --repo "$REPOSITORY" \
    --workflow "$WORKFLOW_ID" \
    --branch "$HEAD_BRANCH" \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId')
if [ "$latest_run" != "$RUN_ID" ]; then
    echo "Run $RUN_ID is superseded by run $latest_run."
    exit 0
fi

job_ids=$(gh api --paginate \
    "repos/$REPOSITORY/actions/runs/$RUN_ID/attempts/$RUN_ATTEMPT/jobs" \
    --jq '.jobs[].id')

for job_id in $job_ids; do
    reclaimed=$(gh api --paginate \
        "repos/$REPOSITORY/check-runs/$job_id/annotations" \
        --jq '.[] | select(.title == "Spot instance reclaimed") | .title')
    if [ -n "$reclaimed" ]; then
        echo "Re-running run $RUN_ID because AWS reclaimed its spot runner."
        gh run rerun "$RUN_ID" --repo "$REPOSITORY"
        exit 0
    fi
done

echo "Run $RUN_ID did not fail because of a spot interruption."
