#!/bin/bash
ulimit -v 4000000
(time SIM_READ_FAULT=1 RF_MAX=400 timeout 3000 /home/user/gates/bin/rf6-sim) > /home/user/gates/rf6.log 2>&1; echo "rc=$?" >> /home/user/gates/rf6.log; echo done > /home/user/gates/rf6.done
