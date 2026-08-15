# SELinux policy work

The server currently stays permissive because its K3s, Flannel, KubeVirt, and
Agent Substrate paths have not yet been covered by a tested Bootsy policy.
Permissive mode still records AVCs. Collect them with:

```sh
sudo ausearch -m AVC,USER_AVC -ts boot
sudo sealert -a /var/log/audit/audit.log
```

Treat generated `audit2allow` output as diagnostic input, not a policy to load
blindly. Each allow rule should be reduced, reviewed, tested through cluster and
VM lifecycle operations, and only then used to move this flavor to enforcing.
