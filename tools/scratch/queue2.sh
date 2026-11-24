#!/bin/bash
echo $$ > /home/user/gates/queue2.pid
for x in kvf kvt-g; do /home/user/gates/bin/gate-one.sh $x; done
