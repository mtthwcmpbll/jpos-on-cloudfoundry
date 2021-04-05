# Introduction

This repository shows a proof-of-concept of a jPOS.org transaction server running in a Cloud Foundry environment.  It's primary purpose is to capture the minimal steps to get it running, along with the context to adapt this to your own custom JPOS instances.

It's mostly based on the existing jPOS tutorials available at the time of the POC, and doesn't provide a complete or production-ready transaction manager.  Instead, it aims to show that the socket-based communication and file-based configuration aren't a blocker for this kind of deployment.