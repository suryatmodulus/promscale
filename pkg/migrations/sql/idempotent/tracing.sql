
CREATE OR REPLACE FUNCTION SCHEMA_TRACING.trace_tree(_trace_id SCHEMA_TRACING.trace_id)
RETURNS TABLE
(
    trace_id SCHEMA_TRACING.trace_id,
    parent_span_id bigint,
    span_id bigint,
    lvl int,
    path bigint[]
)
AS $func$
    WITH RECURSIVE x as
    (
        SELECT
            s1.parent_span_id,
            s1.span_id,
            1 as lvl,
            array[s1.span_id] as path
        FROM SCHEMA_TRACING.span s1
        WHERE s1.trace_id = _trace_id
        AND s1.parent_span_id IS NULL
        UNION ALL
        SELECT
            s2.parent_span_id,
            s2.span_id,
            x.lvl + 1 as lvl,
            x.path || s2.span_id as path
        FROM x
        INNER JOIN SCHEMA_TRACING.span s2
        ON (x.span_id = s2.parent_span_id AND s2.trace_id = _trace_id)
    )
    SELECT
        _trace_id,
        x.parent_span_id,
        x.span_id,
        x.lvl,
        x.path
    FROM x
$func$ LANGUAGE sql STABLE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.trace_tree(SCHEMA_TRACING.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.upstream_spans(_trace_id SCHEMA_TRACING.trace_id, _span_id bigint, _max_dist int default null)
RETURNS TABLE
(
    trace_id SCHEMA_TRACING.trace_id,
    parent_span_id bigint,
    span_id bigint,
    dist int,
    idx int,
    path bigint[]
)
AS $func$
    WITH RECURSIVE x as
    (
        SELECT
          s1.parent_span_id,
          s1.span_id,
          0 as dist,
          1 as idx,
          array[s1.span_id] as path
        FROM SCHEMA_TRACING.span s1
        WHERE s1.trace_id = _trace_id
        AND s1.span_id = _span_id
        UNION ALL
        SELECT
          s2.parent_span_id,
          s2.span_id,
          x.dist + 1 as dist,
          x.idx + 1 as idx,
          x.path || s2.span_id as path
        FROM x
        INNER JOIN SCHEMA_TRACING.span s2
        ON (x.parent_span_id = s2.span_id and s2.trace_id = _trace_id)
        WHERE (_max_dist IS NULL OR x.dist + 1 <= _max_dist)
    )
    SELECT
        _trace_id,
        x.parent_span_id,
        x.span_id,
        x.dist,
        x.idx,
        x.path
    FROM x
$func$ LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.upstream_spans(SCHEMA_TRACING.trace_id, bigint, int) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.downstream_spans(_trace_id SCHEMA_TRACING.trace_id, _span_id bigint, _max_dist int default null)
RETURNS TABLE
(
    trace_id SCHEMA_TRACING.trace_id,
    parent_span_id bigint,
    span_id bigint,
    dist int,
    idx int,
    path bigint[]
)
AS $func$
    WITH RECURSIVE x as
    (
        SELECT
          s1.parent_span_id,
          s1.span_id,
          0 as dist,
          1 as idx,
          array[s1.span_id] as path
        FROM SCHEMA_TRACING.span s1
        WHERE s1.trace_id = _trace_id
        AND s1.span_id = _span_id
        UNION ALL
        SELECT
          s2.parent_span_id,
          s2.span_id,
          x.dist + 1 as dist,
          x.idx + 1 as idx,
          x.path || s2.span_id as path
        FROM x
        INNER JOIN SCHEMA_TRACING.span s2
        ON (x.span_id = s2.parent_span_id and s2.trace_id = _trace_id)
        WHERE (_max_dist IS NULL OR x.dist + 1 <= _max_dist)
    )
    SELECT
        _trace_id,
        x.parent_span_id,
        x.span_id,
        x.dist,
        x.idx,
        x.path
    FROM x
$func$ LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.downstream_spans(SCHEMA_TRACING.trace_id, bigint, int) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.span_tree(_trace_id SCHEMA_TRACING.trace_id, _span_id bigint, _max_dist int default null)
RETURNS TABLE
(
    trace_id SCHEMA_TRACING.trace_id,
    parent_span_id bigint,
    span_id bigint,
    dist int,
    idx int,
    path bigint[]
)
AS $func$
    SELECT
        trace_id,
        parent_span_id,
        span_id,
        dist * -1 as dist,
        idx,
        path
    FROM SCHEMA_TRACING.upstream_spans(_trace_id, _span_id, _max_dist)
    UNION
    SELECT
        trace_id,
        parent_span_id,
        span_id,
        dist as dist,
        idx,
        path
    FROM SCHEMA_TRACING.downstream_spans(_trace_id, _span_id, _max_dist)
$func$ LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.span_tree(SCHEMA_TRACING.trace_id, bigint, int) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.put_tag_key(_key SCHEMA_TRACING.tag_k, _tag_type SCHEMA_TRACING_PUBLIC.tag_type)
RETURNS VOID
AS $func$
    INSERT INTO SCHEMA_TRACING.tag_key AS k (key, tag_type)
    VALUES (_key, _tag_type)
    ON CONFLICT (key) DO
    UPDATE SET tag_type = k.tag_type | EXCLUDED.tag_type
    WHERE k.tag_type & EXCLUDED.tag_type = 0
$func$
LANGUAGE SQL VOLATILE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.put_tag_key(SCHEMA_TRACING.tag_k, SCHEMA_TRACING_PUBLIC.tag_type) TO prom_writer;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.put_tag(_key SCHEMA_TRACING.tag_k, _value SCHEMA_TRACING.tag_v, _tag_type SCHEMA_TRACING_PUBLIC.tag_type)
RETURNS VOID
AS $func$
    INSERT INTO SCHEMA_TRACING.tag AS a (tag_type, key_id, key, value)
    SELECT _tag_type, ak.id, _key, _value
    FROM SCHEMA_TRACING.tag_key ak
    WHERE ak.key = _key
    ON CONFLICT (key, value) DO
    UPDATE SET tag_type = a.tag_type | EXCLUDED.tag_type
    WHERE a.tag_type & EXCLUDED.tag_type = 0
$func$
LANGUAGE SQL VOLATILE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.put_tag(SCHEMA_TRACING.tag_k, SCHEMA_TRACING.tag_v, SCHEMA_TRACING_PUBLIC.tag_type) TO prom_writer;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.has_tag(_tag_map SCHEMA_TRACING.tag_map, _key SCHEMA_TRACING.tag_k)
RETURNS boolean
AS $func$
    SELECT _tag_map ?
    (
        SELECT k.id::text
        FROM SCHEMA_TRACING.tag_key k
        WHERE k.key = _key
        LIMIT 1
    )
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.has_tag(SCHEMA_TRACING.tag_map, SCHEMA_TRACING.tag_k) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.jsonb(_tag_map SCHEMA_TRACING.tag_map)
RETURNS jsonb
AS $func$
    /*
    takes an tag_map which is a map of tag_key.id to tag.id
    and returns a jsonb object containing the key value pairs of tags
    */
    SELECT jsonb_object_agg(a.key, a.value)
    FROM jsonb_each(_tag_map) x -- key is tag_key.id, value is tag.id
    INNER JOIN LATERAL -- inner join lateral enables partition elimination at execution time
    (
        SELECT
            a.key,
            a.value
        FROM SCHEMA_TRACING.tag a
        WHERE a.id = x.value::text::bigint
        AND a.key = (SELECT k.key from SCHEMA_TRACING.tag_key k WHERE k.id = x.key::bigint)
        LIMIT 1
    ) a on (true)
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.jsonb(SCHEMA_TRACING.tag_map) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.jsonb(_tag_map SCHEMA_TRACING.tag_map, VARIADIC _keys SCHEMA_TRACING.tag_k[])
RETURNS jsonb
AS $func$
    /*
    takes an tag_map which is a map of tag_key.id to tag.id
    and returns a jsonb object containing the key value pairs of tags
    only the key/value pairs with keys passed as arguments are included in the output
    */
    SELECT jsonb_object_agg(a.key, a.value)
    FROM jsonb_each(_tag_map) x -- key is tag_key.id, value is tag.id
    INNER JOIN LATERAL -- inner join lateral enables partition elimination at execution time
    (
        SELECT
            a.key,
            a.value
        FROM SCHEMA_TRACING.tag a
        WHERE a.id = x.value::text::bigint
        AND a.key = ANY(_keys) -- ANY works with partition elimination
    ) a on (true)
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.jsonb(SCHEMA_TRACING.tag_map) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.val(_tag_map SCHEMA_TRACING.tag_map, _key SCHEMA_TRACING.tag_k)
RETURNS SCHEMA_TRACING.tag_v
AS $func$
    SELECT a.value
    FROM SCHEMA_TRACING.tag a
    WHERE a.key = _key
    AND _tag_map @> jsonb_build_object(a.key_id, a.id)
    LIMIT 1
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.val(SCHEMA_TRACING.tag_map, SCHEMA_TRACING.tag_k) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.val_text(_tag_map SCHEMA_TRACING.tag_map, _key SCHEMA_TRACING.tag_k)
RETURNS text
AS $func$
    SELECT a.value#>>'{}'
    FROM SCHEMA_TRACING.tag a
    WHERE a.key = _key
    AND _tag_map @> jsonb_build_object(a.key_id, a.id)
    LIMIT 1
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.val_text(SCHEMA_TRACING.tag_map, SCHEMA_TRACING.tag_k) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.get_tag_map(_tags jsonb)
RETURNS SCHEMA_TRACING.tag_map
AS $func$
    SELECT coalesce(jsonb_object_agg(a.key_id, a.id), '{}')::SCHEMA_TRACING.tag_map
    FROM jsonb_each(_tags) x
    INNER JOIN LATERAL
    (
        SELECT a.key_id, a.id
        FROM SCHEMA_TRACING.tag a
        WHERE x.key = a.key
        AND x.value = a.value
        LIMIT 1
    ) a on (true)
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.get_tag_map(jsonb) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps(_key SCHEMA_TRACING.tag_k, _qry jsonpath, _vars jsonb DEFAULT '{}'::jsonb, _silent boolean DEFAULT false)
RETURNS SCHEMA_TRACING.tag_maps
AS $func$
    SELECT coalesce(array_agg(jsonb_build_object(a.key_id, a.id)), '{}')::SCHEMA_TRACING.tag_maps
    FROM SCHEMA_TRACING.tag a
    WHERE a.key = _key
    AND jsonb_path_exists(a.value, _qry, _vars, _silent)
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.tag_maps(SCHEMA_TRACING.tag_k, jsonpath, jsonb, boolean) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps_query(_key SCHEMA_TRACING.tag_k, _path jsonpath)
RETURNS SCHEMA_TRACING.tag_maps
AS $func$
    SELECT SCHEMA_TRACING.tag_maps(_key, _path);
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.tag_maps_query(SCHEMA_TRACING.tag_k, jsonpath) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps_regex(_key SCHEMA_TRACING.tag_k, _pattern text)
RETURNS SCHEMA_TRACING.tag_maps
AS $func$
    SELECT coalesce(array_agg(jsonb_build_object(a.key_id, a.id)), '{}')::SCHEMA_TRACING.tag_maps
    FROM SCHEMA_TRACING.tag a
    WHERE a.key = _key AND
    -- if the jsonb value is a string, apply the regex directly
    -- otherwise, convert the value to a text representation, back to a jsonb string, and then apply
    CASE jsonb_typeof(a.value)
        WHEN 'string' THEN jsonb_path_exists(a.value, format('$?(@ like_regex "%s")', _pattern)::jsonpath)
        ELSE jsonb_path_exists(to_jsonb(a.value#>>'{}'), format('$?(@ like_regex "%s")', _pattern)::jsonpath)
    END
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.tag_maps_regex(SCHEMA_TRACING.tag_k, text) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps_not_regex(_key SCHEMA_TRACING.tag_k, _pattern text)
RETURNS SCHEMA_TRACING.tag_maps
AS $func$
    SELECT coalesce(array_agg(jsonb_build_object(a.key_id, a.id)), '{}')::SCHEMA_TRACING.tag_maps
    FROM SCHEMA_TRACING.tag a
    WHERE a.key = _key AND
    -- if the jsonb value is a string, apply the regex directly
    -- otherwise, convert the value to a text representation, back to a jsonb string, and then apply
    CASE jsonb_typeof(a.value)
        WHEN 'string' THEN jsonb_path_exists(a.value, format('$?(!(@ like_regex "%s"))', _pattern)::jsonpath)
        ELSE jsonb_path_exists(to_jsonb(a.value#>>'{}'), format('$?(!(@ like_regex "%s"))', _pattern)::jsonpath)
    END
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.tag_maps_not_regex(SCHEMA_TRACING.tag_k, text) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.match(_tag_map SCHEMA_TRACING.tag_map, _maps SCHEMA_TRACING.tag_maps)
RETURNS boolean
AS $func$
    SELECT _tag_map @> ANY(_maps)
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.match(SCHEMA_TRACING.tag_map, SCHEMA_TRACING.tag_maps) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_id(_key SCHEMA_TRACING.tag_k)
RETURNS text
AS $func$
    SELECT k.id::text
    FROM SCHEMA_TRACING.tag_key k
    WHERE k.key = _key
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.tag_id(SCHEMA_TRACING.tag_k) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_ids(VARIADIC _keys SCHEMA_TRACING.tag_k[])
RETURNS text[]
AS $func$
    SELECT array_agg(k.id::text)
    FROM SCHEMA_TRACING.tag_key k
    WHERE k.key = ANY(_keys)
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.tag_ids(SCHEMA_TRACING.tag_k[]) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps_equal(_key SCHEMA_TRACING.tag_k, _val SCHEMA_TRACING.tag_v)
RETURNS SCHEMA_TRACING.tag_maps
AS $func$
    SELECT coalesce(array_agg(jsonb_build_object(a.key_id, a.id)), '{}')::SCHEMA_TRACING.tag_maps
    FROM SCHEMA_TRACING.tag a
    WHERE a.key = _key
    AND a.value = _val
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.tag_maps_equal(SCHEMA_TRACING.tag_k, SCHEMA_TRACING.tag_v) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps_not_equal(_key SCHEMA_TRACING.tag_k, _val SCHEMA_TRACING.tag_v)
RETURNS SCHEMA_TRACING.tag_maps
AS $func$
    SELECT coalesce(array_agg(jsonb_build_object(a.key_id, a.id)), '{}')::SCHEMA_TRACING.tag_maps
    FROM SCHEMA_TRACING.tag a
    WHERE a.key = _key
    AND a.value != _val
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.tag_maps_not_equal(SCHEMA_TRACING.tag_k, SCHEMA_TRACING.tag_v) TO prom_reader;

DO $do$
DECLARE
    _tpl1 text =
$sql$
CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps_%1$s_%2$s(_key SCHEMA_TRACING.tag_k, _val %3$s)
RETURNS SCHEMA_TRACING.tag_maps
AS $func$
    SELECT SCHEMA_TRACING.tag_maps_%2$s(_key,to_jsonb(_val))
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
$sql$;
    _tpl2 text =
$sql$
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.tag_maps_%1$s_%2$s(SCHEMA_TRACING.tag_k, %3$s) TO prom_reader;
$sql$;
    _types text[] = ARRAY[
        'text',
        'smallint',
        'int',
        'bigint',
        'bool',
        'real',
        'double precision',
        'numeric',
        'timestamptz',
        'timestamp',
        'time',
        'date'
    ];
    _type text;
BEGIN
    FOREACH _type IN ARRAY _types
    LOOP
        EXECUTE format(_tpl1, replace(_type, ' ', '_'), 'equal', _type);
        EXECUTE format(_tpl2, replace(_type, ' ', '_'), 'equal', _type);
        EXECUTE format(_tpl1, replace(_type, ' ', '_'), 'not_equal', _type);
        EXECUTE format(_tpl2, replace(_type, ' ', '_'), 'not_equal', _type);
    END LOOP;
END;
$do$;

DO $do$
DECLARE
    _tpl1 text =
$sql$
CREATE OR REPLACE FUNCTION SCHEMA_TRACING.tag_maps_%1$s_%2$s(_key SCHEMA_TRACING.tag_k, _val %3$s)
RETURNS SCHEMA_TRACING.tag_maps
AS $func$
    SELECT SCHEMA_TRACING.tag_maps(_key, '%4$s', jsonb_build_object('x', to_jsonb(_val)))
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
$sql$;
    _tpl2 text =
$sql$
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING.tag_maps_%1$s_%2$s(SCHEMA_TRACING.tag_k, %3$s) TO prom_reader;
$sql$;
    _sql record;
BEGIN
    FOR _sql IN
    (
        SELECT
            format
            (
                _tpl1,
                replace(t.type, ' ', '_'),
                f.name,
                t.type,
                format('$?(@ %s $x)', f.jop)
            ) as func,
            format(_tpl2, replace(t.type, ' ', '_'), f.name, t.type) as op
        FROM
        (
            VALUES
            ('smallint'        ),
            ('int'             ),
            ('bigint'          ),
            ('bool'            ),
            ('real'            ),
            ('double precision'),
            ('numeric'         )
        ) t(type)
        CROSS JOIN
        (
            VALUES
            ('less_than'            , '#<'  , '<' ),
            ('less_than_equal'      , '#<=' , '<='),
            ('greater_than'         , '#>'  , '>' ),
            ('greater_than_equal'   , '#>=' , '>=')
        ) f(name, op, jop)
    )
    LOOP
        EXECUTE _sql.func;
        EXECUTE _sql.op;
    END LOOP;
END;
$do$;

CREATE OR REPLACE VIEW SCHEMA_TRACING_PUBLIC.span AS
SELECT
    s.trace_id,
    s.span_id,
    s.trace_state,
    s.parent_span_id,
    s.parent_span_id is null as is_root_span,
    n.name,
    s.span_kind,
    s.start_time,
    s.end_time,
    tstzrange(s.start_time, s.end_time, '[]') as time_range,
    s.end_time - s.start_time as duration,
    s.span_tags,
    s.dropped_tags_count,
    s.event_time,
    s.dropped_events_count,
    s.dropped_link_count,
    s.status_code,
    s.status_message,
    il.name as inst_lib_name,
    il.version as inst_lib_version,
    u1.url as inst_lib_schema_url,
    s.resource_tags,
    s.resource_dropped_tags_count,
    u2.url as resource_schema_url
FROM SCHEMA_TRACING.span s
INNER JOIN SCHEMA_TRACING.span_name n ON (s.name_id = n.id)
INNER JOIN SCHEMA_TRACING.inst_lib il ON (s.inst_lib_id = il.id)
INNER JOIN SCHEMA_TRACING.schema_url u1 on (il.schema_url_id = u1.id)
INNER JOIN SCHEMA_TRACING.schema_url u2 on (il.schema_url_id = u2.id)
;
GRANT SELECT ON SCHEMA_TRACING_PUBLIC.span to prom_reader;

CREATE OR REPLACE VIEW SCHEMA_TRACING_PUBLIC.event AS
SELECT
    e.trace_id,
    e.span_id,
    e.time,
    e.event_number,
    e.name as event_name,
    e.tags as event_tags,
    e.dropped_tags_count,
    s.trace_state,
    n.name as span_name,
    s.span_kind,
    s.start_time as span_start_time,
    s.end_time as span_end_time,
    tstzrange(s.start_time, s.end_time, '[]') as time_range,
    s.end_time - s.start_time as duration,
    s.span_tags,
    s.dropped_tags_count as dropped_span_tags_count,
    s.status_code,
    s.status_message
FROM SCHEMA_TRACING.event e
INNER JOIN SCHEMA_TRACING.span s on (e.span_id = s.span_id AND e.trace_id = s.trace_id)
INNER JOIN SCHEMA_TRACING.span_name n ON (s.name_id = n.id)
;
GRANT SELECT ON SCHEMA_TRACING_PUBLIC.event to prom_reader;

CREATE OR REPLACE VIEW SCHEMA_TRACING_PUBLIC.link AS
SELECT
    s1.trace_id                    ,
    s1.span_id                     ,
    s1.trace_state                 ,
    s1.parent_span_id              ,
    s1.is_root_span                ,
    s1.name                        ,
    s1.span_kind                   ,
    s1.start_time                  ,
    s1.end_time                    ,
    s1.time_range                  ,
    s1.duration                    ,
    s1.span_tags                   ,
    s1.dropped_tags_count          ,
    s1.event_time                  ,
    s1.dropped_events_count        ,
    s1.dropped_link_count          ,
    s1.status_code                 ,
    s1.status_message              ,
    s1.inst_lib_name               ,
    s1.inst_lib_version            ,
    s1.inst_lib_schema_url         ,
    s1.resource_tags               ,
    s1.resource_dropped_tags_count ,
    s1.resource_schema_url         ,
    s2.trace_id                    as linked_trace_id                   ,
    s2.span_id                     as linked_span_id                    ,
    s2.trace_state                 as linked_trace_state                ,
    s2.parent_span_id              as linked_parent_span_id             ,
    s2.is_root_span                as linked_is_root_span               ,
    s2.name                        as linked_name                       ,
    s2.span_kind                   as linked_span_kind                  ,
    s2.start_time                  as linked_start_time                 ,
    s2.end_time                    as linked_end_time                   ,
    s2.time_range                  as linked_time_range                 ,
    s2.duration                    as linked_duration                   ,
    s2.span_tags                   as linked_span_tags                  ,
    s2.dropped_tags_count          as linked_dropped_tags_count         ,
    s2.event_time                  as linked_event_time                 ,
    s2.dropped_events_count        as linked_dropped_events_count       ,
    s2.dropped_link_count          as linked_dropped_link_count         ,
    s2.status_code                 as linked_status_code                ,
    s2.status_message              as linked_status_message             ,
    s2.inst_lib_name               as linked_inst_lib_name              ,
    s2.inst_lib_version            as linked_inst_lib_version           ,
    s2.inst_lib_schema_url         as linked_inst_lib_schema_url        ,
    s2.resource_tags               as linked_resource_tags              ,
    s2.resource_dropped_tags_count as linked_resource_dropped_tags_count,
    s2.resource_schema_url         as linked_resource_schema_url        ,
    k.tags as link_tags,
    k.dropped_tags_count as dropped_link_tags_count
FROM SCHEMA_TRACING.link k
INNER JOIN SCHEMA_TRACING_PUBLIC.span s1 on (k.span_id = s1.span_id and k.trace_id = s1.trace_id)
INNER JOIN SCHEMA_TRACING_PUBLIC.span s2 on (k.linked_span_id = s2.span_id and k.linked_trace_id = s2.trace_id)
;
GRANT SELECT ON SCHEMA_TRACING_PUBLIC.link to prom_reader;




