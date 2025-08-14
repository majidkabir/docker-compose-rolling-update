#!/bin/bash

docker compose up -d --scale service1=2 --scale service2=2 --no-recreate

./check_status.sh service1 &
./check_status.sh service2 &
wait
