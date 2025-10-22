#!/bin/bash
# Author: jmurray1@mit.edu
# Purpose: get percentage of jobs preempted in the mit_preemptable partition
# Date: 2025-10-22
# 

# Usage: ./preempt_stats.sh YYYY-MM-DD YYYY-MM-DD
# Example: ./preempt_stats.sh 2025-04-01 2025-04-30
START_DATE=$1
END_DATE=$2
PARTITION="mit_preemptable"

# Count preempted top-level jobs
PREEMPTED=$(sacct -S $START_DATE -E $END_DATE --partition=$PARTITION --state=PREEMPTED --allusers --format=JobID,User,Partition,State,Start,End,Elapsed | awk '$1 !~ /\\./ && $4 ~ /PREEMP/ {count++} END {print count}')

# Count total top-level jobs
TOTAL=$(sacct -S $START_DATE -E $END_DATE --partition=$PARTITION --allusers --format=JobID,User,Partition,State,Start,End,Elapsed | awk '$1 !~ /\\./ && $1 != "" {count++} END {print count}')

# Calculate percentage
#PERCENT=$(echo "scale=2; $PREEMPTED / $TOTAL * 100" | bc)
PERCENT=$(awk "BEGIN {printf \"%.2f\", $PREEMPTED / $TOTAL * 100}")

# Output results
echo "From $START_DATE to $END_DATE on partition '$PARTITION':"
echo "Total top-level jobs: $TOTAL"
echo "Preempted top-level jobs: $PREEMPTED"
echo "Preemption rate: $PERCENT%"
