
CREATE SCHEMA IF NOT EXISTS SCHEMA_TRACING;
GRANT USAGE ON SCHEMA SCHEMA_TRACING TO prom_reader;

CREATE SCHEMA IF NOT EXISTS SCHEMA_TRACING_PUBLIC;
GRANT USAGE ON SCHEMA SCHEMA_TRACING_PUBLIC TO prom_reader;

CREATE DOMAIN SCHEMA_TRACING.trace_id uuid NOT NULL CHECK (value != '00000000-0000-0000-0000-000000000000');
GRANT USAGE ON DOMAIN SCHEMA_TRACING.trace_id TO prom_reader;

CREATE DOMAIN SCHEMA_TRACING.tag_k text NOT NULL CHECK (value != '');
GRANT USAGE ON DOMAIN SCHEMA_TRACING.tag_k TO prom_reader;

CREATE DOMAIN SCHEMA_TRACING.tag_v jsonb NOT NULL;
GRANT USAGE ON DOMAIN SCHEMA_TRACING.tag_v TO prom_reader;

CREATE DOMAIN SCHEMA_TRACING.tag_map jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(value) = 'object');
GRANT USAGE ON DOMAIN SCHEMA_TRACING.tag_map TO prom_reader;

CREATE DOMAIN SCHEMA_TRACING.tag_maps SCHEMA_TRACING.tag_map[] NOT NULL;
GRANT USAGE ON DOMAIN SCHEMA_TRACING.tag_maps TO prom_reader;

CREATE DOMAIN SCHEMA_TRACING.tag_type smallint NOT NULL; --bitmap, may contain several types
GRANT USAGE ON DOMAIN SCHEMA_TRACING.tag_type TO prom_reader;

CREATE TABLE SCHEMA_TRACING.tag_key
(
    id BIGINT NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tag_type SCHEMA_TRACING.tag_type NOT NULL,
    key SCHEMA_TRACING.tag_k NOT NULL
);
CREATE UNIQUE INDEX ON SCHEMA_TRACING.tag_key (key) INCLUDE (id, tag_type);
GRANT SELECT ON TABLE SCHEMA_TRACING.tag_key TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE SCHEMA_TRACING.tag_key TO prom_writer;
GRANT USAGE ON SEQUENCE SCHEMA_TRACING.tag_key_id_seq TO prom_writer;

CREATE TABLE SCHEMA_TRACING.tag
(
    id BIGINT NOT NULL GENERATED ALWAYS AS IDENTITY,
    tag_type SCHEMA_TRACING.tag_type NOT NULL,
    key_id bigint NOT NULL,
    key SCHEMA_TRACING.tag_k NOT NULL REFERENCES SCHEMA_TRACING.tag_key (key) ON DELETE CASCADE,
    value SCHEMA_TRACING.tag_v NOT NULL,
    UNIQUE (key, value) INCLUDE (id, key_id)
)
PARTITION BY HASH (key);
GRANT SELECT ON TABLE SCHEMA_TRACING.tag TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE SCHEMA_TRACING.tag TO prom_writer;
GRANT USAGE ON SEQUENCE SCHEMA_TRACING.tag_id_seq TO prom_writer;

-- create the partitions of the tag table
DO $block$
DECLARE
    _i bigint;
    _max bigint = 64;
BEGIN
    FOR _i IN 1.._max
    LOOP
        EXECUTE format($sql$
            CREATE TABLE SCHEMA_TRACING.tag_%s PARTITION OF SCHEMA_TRACING.tag FOR VALUES WITH (MODULUS %s, REMAINDER %s)
            $sql$, _i, _max, _i - 1);
        EXECUTE format($sql$
            ALTER TABLE SCHEMA_TRACING.tag_%s ADD PRIMARY KEY (id)
            $sql$, _i);
        EXECUTE format($sql$
            GRANT SELECT ON TABLE SCHEMA_TRACING.tag_%s TO prom_reader
            $sql$, _i);
        EXECUTE format($sql$
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE SCHEMA_TRACING.tag_%s TO prom_writer
            $sql$, _i);
    END LOOP;
END
$block$
;

CREATE TYPE SCHEMA_TRACING.span_kind AS ENUM
(
    'SPAN_KIND_UNSPECIFIED',
    'SPAN_KIND_INTERNAL',
    'SPAN_KIND_SERVER',
    'SPAN_KIND_CLIENT',
    'SPAN_KIND_PRODUCER',
    'SPAN_KIND_CONSUMER'
);
GRANT USAGE ON TYPE SCHEMA_TRACING.span_kind TO prom_reader;

CREATE TYPE SCHEMA_TRACING.status_code AS ENUM
(
    'STATUS_CODE_UNSET',
    'STATUS_CODE_OK',
    'STATUS_CODE_ERROR'
);
GRANT USAGE ON TYPE SCHEMA_TRACING.status_code TO prom_reader;

CREATE TABLE IF NOT EXISTS SCHEMA_TRACING.span_name
(
    id bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL CHECK (name != '') UNIQUE
);
GRANT SELECT ON TABLE SCHEMA_TRACING.span_name TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE SCHEMA_TRACING.span_name TO prom_writer;
GRANT USAGE ON SEQUENCE SCHEMA_TRACING.span_name_id_seq TO prom_writer;

CREATE TABLE IF NOT EXISTS SCHEMA_TRACING.schema_url
(
    id bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    url text NOT NULL CHECK (url != '') UNIQUE
);
GRANT SELECT ON TABLE SCHEMA_TRACING.schema_url TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE SCHEMA_TRACING.schema_url TO prom_writer;
GRANT USAGE ON SEQUENCE SCHEMA_TRACING.schema_url_id_seq TO prom_writer;

CREATE TABLE IF NOT EXISTS SCHEMA_TRACING.inst_lib
(
    id bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    version text NOT NULL,
    schema_url_id BIGINT NOT NULL REFERENCES SCHEMA_TRACING.schema_url(id),
    UNIQUE(name, version, schema_url_id)
);
GRANT SELECT ON TABLE SCHEMA_TRACING.inst_lib TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE SCHEMA_TRACING.inst_lib TO prom_writer;
GRANT USAGE ON SEQUENCE SCHEMA_TRACING.inst_lib_id_seq TO prom_writer;

CREATE TABLE IF NOT EXISTS SCHEMA_TRACING.span
(
    trace_id SCHEMA_TRACING.trace_id NOT NULL,
    span_id bigint NOT NULL,
    parent_span_id bigint NULL,
    name_id bigint NOT NULL,
    start_time timestamptz NOT NULL,
    end_time timestamptz NOT NULL,
    trace_state text,
    span_kind SCHEMA_TRACING.span_kind,
    span_tags SCHEMA_TRACING.tag_map,
    dropped_tags_count int NOT NULL default 0,
    event_time tstzrange NOT NULL default tstzrange('infinity', 'infinity', '()'),
    dropped_events_count int NOT NULL default 0,
    dropped_link_count int NOT NULL default 0,
    status_code SCHEMA_TRACING.status_code,
    status_message text,
    inst_lib_id bigint,
    resource_tags SCHEMA_TRACING.tag_map,
    resource_dropped_tags_count int NOT NULL default 0,
    resource_schema_url_id BIGINT NOT NULL,
    PRIMARY KEY (span_id, trace_id, start_time),
    CHECK (start_time <= end_time)
);
CREATE INDEX ON SCHEMA_TRACING.span USING BTREE (trace_id, parent_span_id);
CREATE INDEX ON SCHEMA_TRACING.span USING GIN (span_tags jsonb_path_ops);
CREATE INDEX ON SCHEMA_TRACING.span USING BTREE (name_id);
--CREATE INDEX ON SCHEMA_TRACING.span USING GIN (jsonb_object_keys(span_tags) array_ops); -- possible way to index key exists
CREATE INDEX ON SCHEMA_TRACING.span USING GIN (resource_tags jsonb_path_ops);
SELECT create_hypertable('SCHEMA_TRACING.span', 'start_time', partitioning_column=>'trace_id', number_partitions=>1);
GRANT SELECT ON TABLE SCHEMA_TRACING.span TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE SCHEMA_TRACING.span TO prom_writer;

CREATE TABLE IF NOT EXISTS SCHEMA_TRACING.event
(
    time timestamptz NOT NULL,
    trace_id SCHEMA_TRACING.trace_id NOT NULL,
    span_id bigint NOT NULL,
    event_number smallint NOT NULL,
    name text NOT NULL CHECK (name != ''),
    tags SCHEMA_TRACING.tag_map,
    dropped_tags_count int NOT NULL DEFAULT 0
);
CREATE INDEX ON SCHEMA_TRACING.event USING GIN (tags jsonb_path_ops);
CREATE INDEX ON SCHEMA_TRACING.event USING BTREE (span_id, time) INCLUDE (trace_id);
SELECT create_hypertable('SCHEMA_TRACING.event', 'time', partitioning_column=>'trace_id', number_partitions=>1);
GRANT SELECT ON TABLE SCHEMA_TRACING.event TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE SCHEMA_TRACING.event TO prom_writer;

CREATE TABLE IF NOT EXISTS SCHEMA_TRACING.link
(
    trace_id SCHEMA_TRACING.trace_id NOT NULL,
    span_id bigint NOT NULL,
    span_start_time timestamptz NOT NULL,
    span_name_id BIGINT NOT NULL REFERENCES SCHEMA_TRACING.span_name (id),
    linked_trace_id SCHEMA_TRACING.trace_id NOT NULL,
    linked_span_id bigint NOT NULL,
    trace_state text,
    tags SCHEMA_TRACING.tag_map,
    dropped_tags_count int NOT NULL DEFAULT 0,
    link_number smallint NOT NULL
);
CREATE INDEX ON SCHEMA_TRACING.link USING BTREE (span_id, span_start_time) INCLUDE (trace_id);
CREATE INDEX ON SCHEMA_TRACING.link USING GIN (tags jsonb_path_ops);
SELECT create_hypertable('SCHEMA_TRACING.link', 'span_start_time', partitioning_column=>'trace_id', number_partitions=>1);
GRANT SELECT ON TABLE SCHEMA_TRACING.link TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE SCHEMA_TRACING.link TO prom_writer;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps_query(_key SCHEMA_TRACING.tag_k, _path jsonpath)
RETURNS SCHEMA_TRACING.tag_maps
AS $sql$
    -- this function body will be replaced later in idempotent script
    -- it's only here so we can create the operators
    SELECT '{}'::SCHEMA_TRACING.tag_maps
$sql$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;

CREATE OPERATOR SCHEMA_TRACING.@? (
    LEFTARG = SCHEMA_TRACING.tag_k,
    RIGHTARG = jsonpath,
    FUNCTION = SCHEMA_TRACING.tag_maps_query
);

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps_regex(_key SCHEMA_TRACING.tag_k, _pattern text)
RETURNS SCHEMA_TRACING.tag_maps
AS $func$
    -- this function body will be replaced later in idempotent script
    -- it's only here so we can create the operators (no "if not exists" for operators)
    SELECT '{}'::SCHEMA_TRACING.tag_maps
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;

CREATE OPERATOR SCHEMA_TRACING.==~ (
    LEFTARG = SCHEMA_TRACING.tag_k,
    RIGHTARG = text,
    FUNCTION = SCHEMA_TRACING.tag_maps_regex
);

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps_not_regex(_key SCHEMA_TRACING.tag_k, _pattern text)
RETURNS SCHEMA_TRACING.tag_maps
AS $func$
    -- this function body will be replaced later in idempotent script
    -- it's only here so we can create the operators (no "if not exists" for operators)
    SELECT '{}'::SCHEMA_TRACING.tag_maps
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;

CREATE OPERATOR SCHEMA_TRACING.!=~ (
    LEFTARG = SCHEMA_TRACING.tag_k,
    RIGHTARG = text,
    FUNCTION = SCHEMA_TRACING.tag_maps_not_regex
);

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.match(_tag_map SCHEMA_TRACING.tag_map, _maps SCHEMA_TRACING.tag_maps)
RETURNS boolean
AS $func$
    -- this function body will be replaced later in idempotent script
    -- it's only here so we can create the operators (no "if not exists" for operators)
    SELECT false
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE STRICT;

CREATE OPERATOR SCHEMA_TRACING.? (
    LEFTARG = SCHEMA_TRACING.tag_map,
    RIGHTARG = SCHEMA_TRACING.tag_maps,
    FUNCTION = SCHEMA_TRACING.match
);

DO $do$
DECLARE
    _tpl1 text =
$sql$
CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps_%s_%s(_key SCHEMA_TRACING.tag_k, _val %s)
RETURNS SCHEMA_TRACING.tag_maps
AS $func$
    -- this function body will be replaced later in idempotent script
    -- it's only here so we can create the operators
    SELECT '{}'::SCHEMA_TRACING.tag_maps
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
$sql$;
    _tpl2 text =
$sql$
CREATE OPERATOR SCHEMA_TRACING.%s (
    LEFTARG = SCHEMA_TRACING.tag_k,
    RIGHTARG = %s,
    FUNCTION = SCHEMA_TRACING.tag_maps_%s_%s
);
$sql$;
    _sql record;
BEGIN
    FOR _sql IN
    (
        SELECT
            format(_tpl1, replace(t.type, ' ', '_'), f.name, t.type) as func,
            format(_tpl2, f.op, t.type, replace(t.type, ' ', '_'), f.name) as op
        FROM
        (
            VALUES
            ('text'),
            ('smallint'),
            ('int'),
            ('bigint'),
            ('bool'),
            ('real'),
            ('double precision'),
            ('numeric'),
            ('timestamptz'),
            ('timestamp'),
            ('time'),
            ('date')
        ) t(type)
        CROSS JOIN
        (
            VALUES
            ('equal', '=='),
            ('not_equal', '!==')
        ) f(name, op)
    )
    LOOP
        EXECUTE _sql.func;
        EXECUTE _sql.op;
    END LOOP;
END;
$do$;

DO $do$
DECLARE
    _tpl1 text =
$sql$
CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps_%s_%s(_key SCHEMA_TRACING.tag_k, _val %s)
RETURNS SCHEMA_TRACING.tag_maps
AS $func$
    -- this function body will be replaced later in idempotent script
    -- it's only here so we can create the operators
    SELECT '{}'::SCHEMA_TRACING.tag_maps
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
$sql$;
    _tpl2 text =
$sql$
CREATE OPERATOR SCHEMA_TRACING.%s (
    LEFTARG = SCHEMA_TRACING.tag_k,
    RIGHTARG = %s,
    FUNCTION = SCHEMA_TRACING.tag_maps_%s_%s
);
$sql$;
    _sql record;
BEGIN
    FOR _sql IN
    (
        SELECT
            format(_tpl1, replace(t.type, ' ', '_'), f.name, t.type) as func,
            format(_tpl2, f.op, t.type, replace(t.type, ' ', '_'), f.name) as op
        FROM
        (
            VALUES
            ('smallint'        ),
            ('int'             ),
            ('bigint'          ),
            ('bool'            ),
            ('real'            ),
            ('double precision'),
            ('numeric'         ),
            ('timestamptz'     ),
            ('timestamp'       ),
            ('time'            ),
            ('date'            )
        ) t(type)
        CROSS JOIN
        (
            VALUES
            ('less_than', '#<'),
            ('less_than_equal', '#<='),
            ('greater_than', '#>'),
            ('greater_than_equal', '#>=')
        ) f(name, op)
    )
    LOOP
        EXECUTE _sql.func;
        EXECUTE _sql.op;
    END LOOP;
END;
$do$;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.span_tag_type()
RETURNS SCHEMA_TRACING.tag_type
AS $sql$
    SELECT (1<<0)::smallint::SCHEMA_TRACING.tag_type
$sql$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.span_tag_type() TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.resource_tag_type()
RETURNS SCHEMA_TRACING.tag_type
AS $sql$
    SELECT (1<<1)::smallint::SCHEMA_TRACING.tag_type
$sql$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.resource_tag_type() TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.event_tag_type()
RETURNS SCHEMA_TRACING.tag_type
AS $sql$
    SELECT (1<<2)::smallint::SCHEMA_TRACING.tag_type
$sql$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.event_tag_type() TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.link_tag_type()
RETURNS SCHEMA_TRACING.tag_type
AS $sql$
    SELECT (1<<3)::smallint::SCHEMA_TRACING.tag_type
$sql$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.link_tag_type() TO prom_reader;

INSERT INTO SCHEMA_TRACING.tag_key (id, key, tag_type)
OVERRIDING SYSTEM VALUE
VALUES
    (1, 'service.name', SCHEMA_TRACING.resource_tag_type()),
    (2, 'service.namespace', SCHEMA_TRACING.resource_tag_type()),
    (3, 'service.instance.id', SCHEMA_TRACING.resource_tag_type()),
    (4, 'service.version', SCHEMA_TRACING.resource_tag_type()),
    (5, 'telemetry.sdk.name', SCHEMA_TRACING.resource_tag_type()),
    (6, 'telemetry.sdk.language', SCHEMA_TRACING.resource_tag_type()),
    (7, 'telemetry.sdk.version', SCHEMA_TRACING.resource_tag_type()),
    (8, 'telemetry.auto.version', SCHEMA_TRACING.resource_tag_type()),
    (9, 'container.name', SCHEMA_TRACING.resource_tag_type()),
    (10, 'container.id', SCHEMA_TRACING.resource_tag_type()),
    (11, 'container.runtime', SCHEMA_TRACING.resource_tag_type()),
    (12, 'container.image.name', SCHEMA_TRACING.resource_tag_type()),
    (13, 'container.image.tag', SCHEMA_TRACING.resource_tag_type()),
    (14, 'faas.name', SCHEMA_TRACING.resource_tag_type()),
    (15, 'faas.id', SCHEMA_TRACING.resource_tag_type()),
    (16, 'faas.version', SCHEMA_TRACING.resource_tag_type()),
    (17, 'faas.instance', SCHEMA_TRACING.resource_tag_type()),
    (18, 'faas.max_memory', SCHEMA_TRACING.resource_tag_type()),
    (19, 'process.pid', SCHEMA_TRACING.resource_tag_type()),
    (20, 'process.executable.name', SCHEMA_TRACING.resource_tag_type()),
    (21, 'process.executable.path', SCHEMA_TRACING.resource_tag_type()),
    (22, 'process.command', SCHEMA_TRACING.resource_tag_type()),
    (23, 'process.command_line', SCHEMA_TRACING.resource_tag_type()),
    (24, 'process.command_args', SCHEMA_TRACING.resource_tag_type()),
    (25, 'process.owner', SCHEMA_TRACING.resource_tag_type()),
    (26, 'process.runtime.name', SCHEMA_TRACING.resource_tag_type()),
    (27, 'process.runtime.version', SCHEMA_TRACING.resource_tag_type()),
    (28, 'process.runtime.description', SCHEMA_TRACING.resource_tag_type()),
    (29, 'webengine.name', SCHEMA_TRACING.resource_tag_type()),
    (30, 'webengine.version', SCHEMA_TRACING.resource_tag_type()),
    (31, 'webengine.description', SCHEMA_TRACING.resource_tag_type()),
    (32, 'host.id', SCHEMA_TRACING.resource_tag_type()),
    (33, 'host.name', SCHEMA_TRACING.resource_tag_type()),
    (34, 'host.type', SCHEMA_TRACING.resource_tag_type()),
    (35, 'host.arch', SCHEMA_TRACING.resource_tag_type()),
    (36, 'host.image.name', SCHEMA_TRACING.resource_tag_type()),
    (37, 'host.image.id', SCHEMA_TRACING.resource_tag_type()),
    (38, 'host.image.version', SCHEMA_TRACING.resource_tag_type()),
    (39, 'os.type', SCHEMA_TRACING.resource_tag_type()),
    (40, 'os.description', SCHEMA_TRACING.resource_tag_type()),
    (41, 'os.name', SCHEMA_TRACING.resource_tag_type()),
    (42, 'os.version', SCHEMA_TRACING.resource_tag_type()),
    (43, 'device.id', SCHEMA_TRACING.resource_tag_type()),
    (44, 'device.model.identifier', SCHEMA_TRACING.resource_tag_type()),
    (45, 'device.model.name', SCHEMA_TRACING.resource_tag_type()),
    (46, 'cloud.provider', SCHEMA_TRACING.resource_tag_type()),
    (47, 'cloud.account.id', SCHEMA_TRACING.resource_tag_type()),
    (48, 'cloud.region', SCHEMA_TRACING.resource_tag_type()),
    (49, 'cloud.availability_zone', SCHEMA_TRACING.resource_tag_type()),
    (50, 'cloud.platform', SCHEMA_TRACING.resource_tag_type()),
    (51, 'deployment.environment', SCHEMA_TRACING.resource_tag_type()),
    (52, 'k8s.cluster', SCHEMA_TRACING.resource_tag_type()),
    (53, 'k8s.node.name', SCHEMA_TRACING.resource_tag_type()),
    (54, 'k8s.node.uid', SCHEMA_TRACING.resource_tag_type()),
    (55, 'k8s.namespace.name', SCHEMA_TRACING.resource_tag_type()),
    (56, 'k8s.pod.uid', SCHEMA_TRACING.resource_tag_type()),
    (57, 'k8s.pod.name', SCHEMA_TRACING.resource_tag_type()),
    (58, 'k8s.container.name', SCHEMA_TRACING.resource_tag_type()),
    (59, 'k8s.replicaset.uid', SCHEMA_TRACING.resource_tag_type()),
    (60, 'k8s.replicaset.name', SCHEMA_TRACING.resource_tag_type()),
    (61, 'k8s.deployment.uid', SCHEMA_TRACING.resource_tag_type()),
    (62, 'k8s.deployment.name', SCHEMA_TRACING.resource_tag_type()),
    (63, 'k8s.statefulset.uid', SCHEMA_TRACING.resource_tag_type()),
    (64, 'k8s.statefulset.name', SCHEMA_TRACING.resource_tag_type()),
    (65, 'k8s.daemonset.uid', SCHEMA_TRACING.resource_tag_type()),
    (66, 'k8s.daemonset.name', SCHEMA_TRACING.resource_tag_type()),
    (67, 'k8s.job.uid', SCHEMA_TRACING.resource_tag_type()),
    (68, 'k8s.job.name', SCHEMA_TRACING.resource_tag_type()),
    (69, 'k8s.cronjob.uid', SCHEMA_TRACING.resource_tag_type()),
    (70, 'k8s.cronjob.name', SCHEMA_TRACING.resource_tag_type()),
    (71, 'net.transport', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (72, 'net.peer.ip', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (73, 'net.peer.port', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (74, 'net.peer.name', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (75, 'net.host.ip', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (76, 'net.host.port', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (77, 'net.host.name', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (78, 'net.host.connection.type', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (79, 'net.host.connection.subtype', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (80, 'net.host.carrier.name', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (81, 'net.host.carrier.mcc', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (82, 'net.host.carrier.mnc', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (83, 'net.host.carrier.icc', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (84, 'peer.service', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (85, 'enduser.id', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (86, 'enduser.role', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (87, 'enduser.scope', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (88, 'thread.id', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (89, 'thread.name', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (90, 'code.function', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (91, 'code.namespace', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (92, 'code.filepath', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (93, 'code.lineno', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (94, 'http.method', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (95, 'http.url', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (96, 'http.target', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (97, 'http.host', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (98, 'http.scheme', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (99, 'http.status_code', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (100, 'http.flavor', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (101, 'http.user_agent', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (102, 'http.request_content_length', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (103, 'http.request_content_length_uncompressed', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (104, 'http.response_content_length', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (105, 'http.response_content_length_uncompressed', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (106, 'http.server_name', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (107, 'http.route', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (108, 'http.client_ip', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (109, 'db.system', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (110, 'db.connection_string', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (111, 'db.user', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (112, 'db.jdbc.driver_classname', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (113, 'db.mssql.instance_name', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (114, 'db.name', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (115, 'db.statement', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (116, 'db.operation', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (117, 'db.hbase.namespace', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (118, 'db.redis.database_index', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (119, 'db.mongodb.collection', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (120, 'db.sql.table', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (121, 'db.cassandra.keyspace', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (122, 'db.cassandra.page_size', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (123, 'db.cassandra.consistency_level', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (124, 'db.cassandra.table', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (125, 'db.cassandra.idempotence', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (126, 'db.cassandra.speculative_execution_count', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (127, 'db.cassandra.coordinator.id', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (128, 'db.cassandra.coordinator.dc', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (129, 'rpc.system', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (130, 'rpc.service', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (131, 'rpc.method', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (132, 'rpc.grpc.status_code', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (133, 'message.type', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (134, 'message.id', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (135, 'message.compressed_size', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (136, 'message.uncompressed_size', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (137, 'rpc.jsonrpc.version', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (138, 'rpc.jsonrpc.request_id', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (139, 'rpc.jsonrpc.error_code', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (140, 'rpc.jsonrpc.error_message', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (141, 'messaging.system', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (142, 'messaging.destination', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (143, 'messaging.destination_kind', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (144, 'messaging.temp_destination', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (145, 'messaging.protocol', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (146, 'messaging.url', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (147, 'messaging.message_id', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (148, 'messaging.conversation_id', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (149, 'messaging.message_payload_size_bytes', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (150, 'messaging.message_payload_compressed_size_bytes', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (151, 'messaging.operation', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (152, 'messaging.consumer_id', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (153, 'messaging.rabbitmq.routing_key', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (154, 'messaging.kafka.message_key', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (155, 'messaging.kafka.consumer_group', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (156, 'messaging.kafka.client_id', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (157, 'messaging.kafka.partition', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (158, 'messaging.kafka.tombstone', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (159, 'faas.trigger', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (160, 'faas.speculative_execution_count', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (161, 'faas.coldstart', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (162, 'faas.invoked_name', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (163, 'faas.invoked_provider', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (164, 'faas.invoked_region', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (165, 'faas.document.collection', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (166, 'faas.document.operation', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (167, 'faas.document.time', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (168, 'faas.document.name', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (169, 'faas.time', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (170, 'faas.cron', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (171, 'exception.type', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (172, 'exception.message', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (173, 'exception.stacktrace', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type()),
    (174, 'exception.escaped', SCHEMA_TRACING.span_tag_type() | SCHEMA_TRACING.event_tag_type() | SCHEMA_TRACING.link_tag_type())
;
SELECT setval('SCHEMA_TRACING.tag_key_id_seq', 1000);
