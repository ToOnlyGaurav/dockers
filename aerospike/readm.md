aql
select * from <<NAMESPACE>>.*;
asadm
info
info set
show sets;
show sindex
show sindex like <<INDEX_NAME>>;
manage sindex delete <<INDEX_NAME>> ns <<NAMESPACE>>;
set output json
set output table
SHOW NAMESPACES
SHOW SETS
SHOW INDEXES
show stop-writes
manage config namespace mynamespace param stop-writes-sys-memory-pct to 100
asinfo -v "set-config:context=namespace;id=bar;strong-consistency-allow-expunge=true"
Durable delete. Application was not doing the durable delete.  strong-consistency-allow-expunge true
show stat like replica
show roster
show pmap
