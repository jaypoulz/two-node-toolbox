# Cluster Shutdown Cron Job Setup

## Installation

1. **Copy the script to your home directory:**
   ```bash
   cp ./shutdown-cluster.sh ~/bin/shutdown-cluster.sh
   chmod +x ~/bin/shutdown-cluster.sh
   ```

2. **Add to crontab:**
   ```bash
   crontab -e
   ```

3. **Add this line to run at 6pm daily:**
   ```
   0 18 * * * $HOME/bin/shutdown-cluster.sh
   ```

   Or if you want it to run Monday-Friday only:
   ```
   0 18 * * 1-5 $HOME/bin/shutdown-cluster.sh
   ```

## Cron Schedule Format
```
* * * * *
│ │ │ │ │
│ │ │ │ └─── Day of week (0-7, where 0 and 7 are Sunday)
│ │ │ └───── Month (1-12)
│ │ └─────── Day of month (1-31)
│ └───────── Hour (0-23)
└─────────── Minute (0-59)
```

## Check Logs

Logs are written to: `~/.logs/shutdown-cluster.log`

```bash
tail -f ~/.logs/shutdown-cluster.log
```

## Verify Cron Job

List your cron jobs:
```bash
crontab -l
```

## Test Manually

You can test the script manually:
```bash
~/bin/shutdown-cluster.sh
```
