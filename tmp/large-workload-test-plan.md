# Sail Large-Workload Test Plan

## Context

The goal discussed in Slack is to run two or three genuinely large, long-running jobs on the production test customer. Most previous testing has used nominal workloads such as `SELECT 1`. Shehab approved the larger tests, asked that everything be cleaned up afterward, and noted that larger datasets may require blocking shuffle.

## Recommendation: Use FineWeb for Data Preparation

Hugging Face makes sense as the data source. The workload should be corpus preparation rather than model training or inference, since Sail is the distributed data-processing layer.

FineWeb is a strong fit because it is public, Parquet-backed, and available at controlled scales:

| Configuration | Parquet size | Rows |
| --- | ---: | ---: |
| `sample-10BT` | 30.6 GB | 14.9M |
| `sample-100BT` | 302.6 GB | 147.6M |
| `sample-350BT` | 1.061 TB | 518.5M |

Sail can read the dataset through an `hf://` path such as:

```text
hf://datasets/HuggingFaceFW/fineweb@~parquet/sample-100BT/train
```

## Test 1: Python Corpus-Curation Job

Start with `sample-100BT`.

1. Read the Hugging Face Parquet dataset.
2. Reject empty records and records with low language scores.
3. Filter to a useful token-count range.
4. Extract the hostname from each URL.
5. Compute a content hash from `text`.
6. Globally deduplicate by content hash, retaining the newest record.
7. Repartition by crawl dump.
8. Write Parquet to test-customer S3 and register it in the Glue catalog.

Use blocking shuffle for the deduplication and repartitioning.

This exercises:

- Sail's Hugging Face integration
- sustained network reads and S3 writes
- CPU-heavy string processing and hashing
- global shuffle and sorting
- worker scaling
- catalog access
- long-running logs, heartbeats, metering, and cleanup

The 30 GB dataset should be the dry run, not the final test.

## Test 2: SQL Full-Corpus Analytics Job

Run this against the staged Glue table so Hugging Face network variance does not affect the result.

Group by crawl, month, and hostname, calculating:

- document count
- total and average token count
- p50 and p95 token count
- total text bytes
- top 100 domains within each crawl

Write the result to another catalog table.

This validates the SQL job path separately and puts pressure on hash aggregation, window functions, shuffle, and catalog writes. It also leaves behind a useful, inspectable result instead of merely consuming compute.

## Test 3: Concurrent Workloads

After both jobs succeed independently, rerun them simultaneously:

- one Python curation job
- one SQL aggregation job
- optionally one notebook or session querying the output while they run

This should reveal platform problems that single-user QA will not:

- workload isolation
- Karpenter scaling under overlapping demand
- status or log cross-contamination
- control-plane bottlenecks
- billing attribution
- cleanup races
- one workload starving another

If the 302 GB jobs complete too quickly to test endurance, repeat the curation job using `sample-350BT` rather than artificially slowing the code down.

## What to Record

Do not define success as only "the job finished." Capture:

- exact input and output row counts
- `count(*) = count(distinct content_hash)` after deduplication
- runtime and time to first task
- bytes read and written
- maximum worker count
- peak CPU, memory, and shuffle usage
- worker or task retries
- billable vCPU time and approximate cost per TB
- whether logs continued updating for the entire run
- whether output was immediately queryable through the catalog
- whether workloads, pods, nodes, temporary S3 objects, and billing state cleaned up correctly

The main output should be a baseline for what a 300 GB Sail workload costs and how it behaves, plus a concrete list of anything that breaks during a multi-hour workload.

## Follow-Up Dataset: OpenAlex

After FineWeb, use the Hugging Face OpenAlex snapshot. It contains more than 250 million scholarly works, more than 100 million authors, and normalized Parquet relationship tables.

A realistic workload would join:

```text
works → authorships → institutions
```

Then aggregate publications and citation counts by year, country, and topic. This would test large-to-large joins better than FineWeb.

For the initial large-workload task, start with the FineWeb Python curation job, SQL aggregation job, and concurrent rerun.

## Sources

- Slack thread: https://lakesail.slack.com/archives/C090HGH9N7Q/p1786390225733469
- Sail Hugging Face support: https://docs.lakesail.com/sail/latest/guide/storage/hf.html
- FineWeb: https://huggingface.co/datasets/HuggingFaceFW/fineweb
- OpenAlex: https://huggingface.co/datasets/Mearman/OpenAlex
