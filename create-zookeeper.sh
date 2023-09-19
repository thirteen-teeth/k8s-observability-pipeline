#!/bin/bash

kubectl create namespace zoo1ns
kubectl apply -f teeth-zookeeper.yaml -n zoo1ns