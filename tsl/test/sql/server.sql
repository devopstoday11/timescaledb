-- This file and its contents are licensed under the Timescale License.
-- Please see the included NOTICE for copyright information and
-- LICENSE-TIMESCALE for a copy of the license.

-- Need to be super user to create extension and add servers
\c :TEST_DBNAME :ROLE_SUPERUSER;
ALTER ROLE :ROLE_DEFAULT_PERM_USER PASSWORD 'perm_user_pass';
GRANT USAGE ON FOREIGN DATA WRAPPER timescaledb_fdw TO :ROLE_DEFAULT_PERM_USER;

CREATE OR REPLACE FUNCTION show_servers()
RETURNS TABLE(server_name NAME, host TEXT, port INT, dbname NAME)
AS :TSL_MODULE_PATHNAME, 'test_server_show' LANGUAGE C;

-- Cleanup from other potential tests that created these databases
SET client_min_messages TO ERROR;
DROP DATABASE IF EXISTS server_1;
DROP DATABASE IF EXISTS server_2;
DROP DATABASE IF EXISTS server_3;
DROP DATABASE IF EXISTS server_4;
SET client_min_messages TO NOTICE;

SET ROLE :ROLE_DEFAULT_PERM_USER;

-- Create server with DDL statements as reference. NOTE, 'IF NOT
-- EXISTS' on 'CREATE SERVER' and 'CREATE USER MAPPING' is not
-- supported on PG 9.6
CREATE SERVER server_1 FOREIGN DATA WRAPPER timescaledb_fdw
OPTIONS (host 'localhost', port '15432', dbname 'server_1');

-- Create a user mapping for the server
CREATE USER MAPPING FOR :ROLE_SUPERUSER SERVER server_1 OPTIONS (user 'cluster_user_1');

-- Add servers using TimescaleDB server management API
RESET ROLE;
SELECT * FROM add_server('server_2', database => 'server_2', local_user => :'ROLE_DEFAULT_PERM_USER', remote_user => :'ROLE_DEFAULT_PERM_USER', password => 'perm_user_pass', bootstrap_user => :'ROLE_SUPERUSER');
SET ROLE :ROLE_DEFAULT_PERM_USER;

\set ON_ERROR_STOP 0
-- Add again
SELECT * FROM add_server('server_2', password => 'perm_user_pass');
-- Add without password
SELECT * FROM add_server('server_3');
-- Add NULL server
SELECT * FROM add_server(NULL);
\set ON_ERROR_STOP 1

RESET ROLE;
-- Should not generate error with if_not_exists option
SELECT * FROM add_server('server_2', database => 'server_2', local_user => :'ROLE_DEFAULT_PERM_USER', remote_user => :'ROLE_DEFAULT_PERM_USER', password => 'perm_user_pass', bootstrap_user => :'ROLE_SUPERUSER', if_not_exists => true);

SELECT * FROM add_server('server_3', database => 'server_3', local_user => :'ROLE_DEFAULT_PERM_USER', remote_user => 'cluster_user_2', bootstrap_user => :'ROLE_SUPERUSER');
SET ROLE :ROLE_DEFAULT_PERM_USER;

-- Server exists, but no user mapping
CREATE SERVER server_4 FOREIGN DATA WRAPPER timescaledb_fdw
OPTIONS (host 'localhost', port '15432', dbname 'server_4');

-- User mapping should be added with NOTICE
RESET ROLE;
SELECT * FROM add_server('server_4', database => 'server_4', local_user => :'ROLE_DEFAULT_PERM_USER', remote_user => :'ROLE_DEFAULT_PERM_USER', password => 'perm_user_pass', bootstrap_user => :'ROLE_SUPERUSER', if_not_exists => true);
SET ROLE :ROLE_DEFAULT_PERM_USER;

SELECT * FROM show_servers();

-- Should show up in view
SELECT server_name, options FROM timescaledb_information.server
ORDER BY server_name;

-- List foreign servers and user mappings
SELECT srvname, srvoptions
FROM pg_foreign_server
ORDER BY srvname;

-- Need super user permissions to list user mappings
RESET ROLE;

SELECT rolname, srvname, umoptions
FROM pg_user_mapping um, pg_authid a, pg_foreign_server fs
WHERE a.oid = um.umuser AND fs.oid = um.umserver
ORDER BY srvname;
SET ROLE :ROLE_DEFAULT_PERM_USER;

-- Delete a server
\set ON_ERROR_STOP 0
-- Cannot delete if not owner
SELECT * FROM delete_server('server_3');
-- Must use cascade because of user mappings
RESET ROLE;
SELECT * FROM delete_server('server_3');
\set ON_ERROR_STOP 1
-- Should work as superuser with cascade
SELECT * FROM delete_server('server_3', cascade => true);
SET ROLE :ROLE_DEFAULT_PERM_USER;

SELECT srvname, srvoptions
FROM pg_foreign_server;

RESET ROLE;
SELECT rolname, srvname, umoptions
FROM pg_user_mapping um, pg_authid a, pg_foreign_server fs
WHERE a.oid = um.umuser AND fs.oid = um.umserver
ORDER BY srvname;

\set ON_ERROR_STOP 0
-- Deleting a non-existing server generates error
SELECT * FROM delete_server('server_3');
\set ON_ERROR_STOP 1

-- Deleting non-existing server with "if_exists" set does not generate error
SELECT * FROM delete_server('server_3', if_exists => true);

SELECT * FROM show_servers();

-- Set up servers to receive distributed tables (database may be left over from other tests)
CREATE USER MAPPING FOR :ROLE_SUPERUSER SERVER server_2;
CREATE USER MAPPING FOR :ROLE_SUPERUSER SERVER server_4;
SET client_min_messages TO ERROR;
DROP DATABASE IF EXISTS server_1;
DROP DATABASE IF EXISTS server_2;
DROP DATABASE IF EXISTS server_4;
SET client_min_messages TO INFO;
CREATE DATABASE server_1;
CREATE DATABASE server_2;
CREATE DATABASE server_4;
\c server_1;
SET client_min_messages TO ERROR;
CREATE EXTENSION timescaledb;
CREATE ROLE cluster_user_1 WITH LOGIN;
\c server_2;
SET client_min_messages TO ERROR;
CREATE EXTENSION timescaledb;
\c server_4;
SET client_min_messages TO ERROR;
CREATE EXTENSION timescaledb;
\c :TEST_DBNAME :ROLE_SUPERUSER;

-- Test that servers are added to a hypertable
CREATE TABLE disttable(time timestamptz, device int, temp float);

SELECT * FROM create_hypertable('disttable', 'time', replication_factor => 1);

-- All servers should be added.
SELECT * FROM _timescaledb_catalog.hypertable_server;

DROP TABLE disttable;
-- Need to distribute table drop
\c server_1;
DROP TABLE disttable;
\c server_2;
DROP TABLE disttable;
\c server_4;
DROP TABLE disttable;
\c :TEST_DBNAME :ROLE_SUPERUSER;

CREATE TABLE disttable(time timestamptz, device int, temp float);

\set ON_ERROR_STOP 0
-- Attach server should fail when called on a non-hypertable
SELECT * FROM attach_server('disttable', 'server_1');

-- Test some bad create_hypertable() parameter values for distributed hypertables
-- Bad replication factor
SELECT * FROM create_hypertable('disttable', 'time', replication_factor => 0, servers => '{ "server_2", "server_4" }');
SELECT * FROM create_hypertable('disttable', 'time', replication_factor => 32768);
SELECT * FROM create_hypertable('disttable', 'time', replication_factor => -1);

-- Non-existing server
SELECT * FROM create_hypertable('disttable', 'time', replication_factor => 1, servers => '{ "server_3" }');
\set ON_ERROR_STOP 1

-- Use a subset of servers
SELECT * FROM create_hypertable('disttable', 'time', replication_factor => 1, servers => '{ "server_2", "server_4" }');

SELECT * FROM _timescaledb_catalog.hypertable_server;

-- Deleting a server should remove the hypertable_server mappings for that server
SELECT * FROM delete_server('server_2', cascade => true);

SELECT * FROM _timescaledb_catalog.hypertable_server;

-- Should also clean up hypertable_server when using standard DDL commands
DROP SERVER server_4 CASCADE;

SELECT * FROM _timescaledb_catalog.hypertable_server;

-- Attach server should now succeed
SELECT * FROM attach_server('disttable', 'server_1');

SELECT * FROM _timescaledb_catalog.hypertable_server;

-- Some attach server error cases
\set ON_ERROR_STOP 0
-- Invalid arguments
SELECT * FROM attach_server(NULL, 'server_1', true);
SELECT * FROM attach_server('disttable', NULL, true);

-- Deleted server
SELECT * FROM attach_server('disttable', 'server_2');

-- Attchinging to an already attached server without 'if_not_exists'
SELECT * FROM attach_server('disttable', 'server_1', false);
\set ON_ERROR_STOP 1

-- Attach if not exists
SELECT * FROM attach_server('disttable', 'server_1', true);

-- Creating a distributed hypertable without any servers should fail
DROP TABLE disttable;
CREATE TABLE disttable(time timestamptz, device int, temp float);

\set ON_ERROR_STOP 0
SELECT * FROM create_hypertable('disttable', 'time', replication_factor => 1, servers => '{ }');
\set ON_ERROR_STOP 1

SELECT * FROM delete_server('server_1', cascade => true);
SELECT * FROM show_servers();

\set ON_ERROR_STOP 0
SELECT * FROM create_hypertable('disttable', 'time', replication_factor => 1);
\set ON_ERROR_STOP 1

DROP DATABASE server_1;
DROP DATABASE server_2;
DROP DATABASE server_4;
