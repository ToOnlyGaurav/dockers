## Bash commands for Aerospike
aql
asadm

## AQL commands
echo "show namespaces" | aql
echo "show sets" | aql
echo "show indexes" | aql

## Asadm commands
asadm -e "show sindex"
asadm -e "show sindex like <index_name>"
asadm -e "show stop-writes"
asadm -e "enable; manage config namespace mynamespace param stop-writes-sys-memory-pct to 100"
asadm -e "asinfo -v 'set-config:context=namespace;id=bar;strong-consistency-allow-expunge=true'"
asadm -e "show stat like replica"
asadm -e "show roster"
asadm -e "show pmap"
asadm -e "enable; asinfo -v statistics"
asadm -e "show stat"
asadm -e "enable; manage sindex delete myindex ns mynamespace"