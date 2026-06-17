## SURU Platform — ZeekControl global configuration
## TEMPLATE: tier1-perimeter/templates/zeek/zeekctl.cfg.tpl
## Rendered by: tier2-telemetry/build/lib/render-zeek.sh
## Output to:   tier1-perimeter/rendered/<platform>/zeek/zeekctl.cfg
## Deployed to: /usr/local/etc/zeekctl.cfg
##
## Template tokens (substituted at render time):
##   __ZEEK_MAILTO__ — recipient for zeekctl alert emails (env: ZEEK_MAILTO, default: root)

###############################################
# Mail Options

MailTo = __ZEEK_MAILTO__
SendMail = /usr/sbin/sendmail
MailConnectionSummary = 0
MinDiskSpace = 15
MailHostUpDown = 0

###############################################
# Logging Options

# Rotation interval in seconds for log files on manager (or standalone) node.
LogRotationInterval = 3600

# Expiration interval for archived log files in LogDir.
LogExpireInterval = 7day

StatsLogEnable = 0
StatsLogExpireInterval = 0

###############################################
# Other Options

StatusCmdShowAll = 0

# Site policy loaded by zeekctl deploy — SURU keeps this as local.zeek.
SitePolicyScripts = local.zeek

# LogDir is where zeekctl archives rotated log files.
# NOTE: Log::default_logdir in local.zeek writes live logs directly to /var/log/zeek;
# zeekctl reads from SpoolDir for rotation, which is separate.
LogDir = /var/log/zeek

SpoolDir = /usr/local/spool
CfgDir = /usr/local/etc
