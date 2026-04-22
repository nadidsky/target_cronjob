# target_cronjob
A POSIX sh cron script (every minute) that, after 19:30 on TARGET open days, runs a report job covering all calendar dates since the last successful run — automatically backfilling weekends, holidays, and failed days. Silent on most ticks; single-instance locked; retries until success is recorded.
