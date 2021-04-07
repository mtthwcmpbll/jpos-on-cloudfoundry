#!/usr/bin/env bash

PWD="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

rm -rf $PWD/results
mkdir -p $PWD/results

jmeter -n -t $PWD/jmeter-test.jmx -l $PWD/results/jmeter-test.csv -e -o $PWD/results/html