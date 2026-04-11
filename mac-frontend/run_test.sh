swift test --filter FastIntegrationTests 2>&1 > /tmp/out.log
cat /tmp/out.log | tail -n 20
