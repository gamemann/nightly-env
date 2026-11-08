#!/bin/bash
ps -eo pid,rss,comm --no-headers | awk '$2 > 512000 && $3 !~ /^(sshd|systemd)$/ {print $1}' | xargs -r kill
