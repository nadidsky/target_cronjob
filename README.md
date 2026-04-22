# target_cronjob 
A POSIX shell script designed to run as a cron job every minute on a Linux/Unix server. It automates the execution of a report job that must cover every calendar day since the last successful run, respecting the TARGET financial settlement calendar used by European central banks.

Each minute it silently checks four conditions before doing anything: is it past 19:30, is today a TARGET open day, has it already succeeded today, and is another instance running? Only when all four pass does it actually execute.

When it does run, it looks up the last date it successfully completed, builds a chronological list of every day from the day after that up to today, and passes that full list to the report job as arguments. This means it automatically catches up on weekends, public holidays, and any days where the job previously failed — without ever double-processing a day that already succeeded.You said: less than 350 charactersless than 350 characters7:39 AMClaude responded: A POSIX sh cron script (every minute) that, after 19:30 on TARGET open days, runs a report job covering all calendar dates since the last successful run — auto…A POSIX sh cron script (every minute) that, after 19:30 on TARGET open days, runs a report job covering all calendar dates since the last successful run — automatically backfilling weekends, holidays, and failed days. Silent on most ticks; single-instance locked; retries until success is recorded.

# Be careful, this code is fully AI Generated and not yet tested
