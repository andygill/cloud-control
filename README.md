# Cloud Control

Makefile for my Google cloud instances

Start using

```
make find-zone
```

This will look and find a machine in the US. Then type

```
make setup-instance
```

which will populate it. If you get connection refused (a race condition), use `setup-instance` again.
Make sure to agree to installing the driver. This will leave you in the machine, so ^D to get back and
continue.

I can go from cold boot to running Fooocus or ollama in less than 10 minutes.
