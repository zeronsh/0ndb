#!/bin/bash
echo $$ > /home/user/gates/queue3.pid
for x in kvf2-g kvt2-g; do /home/user/gates/bin/gate-one.sh $x; done
