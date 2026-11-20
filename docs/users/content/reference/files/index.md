---
title: Files
description: The files reprobuild reads or writes, field by field.
kind: reference
persona: machine-owner
order: 20
---

# Files

This section describes, field by field, the files reprobuild writes for other tools to read.

| File | What it is |
|---|---|
| [Home profile export](home-export.md) | The JSON document `repro home export` writes and Nix reads |
| [Host facts](host-facts.md) | The JSON document `repro home facts` and `reprobuild.lib.homeManagerFacts` write and `repro home compare` reads |
