# Atomic updates and rollback

`bootc-fetch-apply-updates.timer` checks weekly with a randomized delay and
stages an updated image. It does not force a reboot. Inspect the running and
staged deployments with:

```sh
bootsy-status
sudo bootc upgrade --check
```

Reboot in your maintenance window to enter a staged deployment. If it is bad,
stop automated staging while recovering, queue the previous deployment, and
reboot:

```sh
sudo systemctl disable --now bootc-fetch-apply-updates.timer
sudo bootc rollback
sudo systemctl reboot
```

After diagnosing the bad build, switch to a known immutable `sha-...` tag or a
fixed newer image before re-enabling the timer. Remember that bootc rollback
also returns `/etc` to the prior deployment's merged state; persistent
application data under `/var` is not rolled back.
