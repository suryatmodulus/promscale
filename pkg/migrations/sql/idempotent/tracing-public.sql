
CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.trace_tree(_trace_id SCHEMA_TRACING_PUBLIC.trace_id)
RETURNS TABLE
(
    trace_id SCHEMA_TRACING_PUBLIC.trace_id,
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
        INNER JOIN LATERAL
        (
            SELECT
                s2.parent_span_id,
                s2.span_id
            FROM SCHEMA_TRACING.span s2
            WHERE s2.trace_id = _trace_id
            AND s2.parent_span_id = x.span_id
        ) s2 ON (true)
    )
    SELECT
        _trace_id,
        x.parent_span_id,
        x.span_id,
        x.lvl,
        x.path
    FROM x
$func$ LANGUAGE sql STABLE STRICT PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.trace_tree(SCHEMA_TRACING_PUBLIC.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.upstream_spans(_trace_id SCHEMA_TRACING_PUBLIC.trace_id, _span_id bigint, _max_dist int default null)
RETURNS TABLE
(
    trace_id SCHEMA_TRACING_PUBLIC.trace_id,
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
        INNER JOIN LATERAL
        (
            SELECT
                s2.parent_span_id,
                s2.span_id
            FROM SCHEMA_TRACING.span s2
            WHERE s2.trace_id = _trace_id
            AND s2.span_id = x.parent_span_id
        ) s2 ON (true)
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
$func$ LANGUAGE sql STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.upstream_spans(SCHEMA_TRACING_PUBLIC.trace_id, bigint, int) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.downstream_spans(_trace_id SCHEMA_TRACING_PUBLIC.trace_id, _span_id bigint, _max_dist int default null)
RETURNS TABLE
(
    trace_id SCHEMA_TRACING_PUBLIC.trace_id,
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
        INNER JOIN LATERAL
        (
            SELECT *
            FROM SCHEMA_TRACING.span s2
            WHERE s2.trace_id = _trace_id
            AND s2.parent_span_id = x.span_id
        ) s2 ON (true)
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
$func$ LANGUAGE sql STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.downstream_spans(SCHEMA_TRACING_PUBLIC.trace_id, bigint, int) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.sibling_spans(_trace_id SCHEMA_TRACING_PUBLIC.trace_id, _span_id bigint)
RETURNS TABLE
(
    trace_id SCHEMA_TRACING_PUBLIC.trace_id,
    parent_span_id bigint,
    span_id bigint
)
AS $func$
    SELECT
        _trace_id,
        s.parent_span_id,
        s.span_id
    FROM SCHEMA_TRACING.span s
    WHERE s.trace_id = _trace_id
    AND s.parent_span_id =
    (
        SELECT parent_span_id
        FROM SCHEMA_TRACING.span x
        WHERE x.trace_id = _trace_id
        AND x.span_id = _span_id
    )
$func$ LANGUAGE sql STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.sibling_spans(SCHEMA_TRACING_PUBLIC.trace_id, bigint) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.span_tree(_trace_id SCHEMA_TRACING_PUBLIC.trace_id, _span_id bigint, _max_dist int default null)
RETURNS TABLE
(
    trace_id SCHEMA_TRACING_PUBLIC.trace_id,
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
    FROM SCHEMA_TRACING_PUBLIC.upstream_spans(_trace_id, _span_id, _max_dist)
    UNION ALL
    SELECT
        trace_id,
        parent_span_id,
        span_id,
        dist,
        idx,
        path
    FROM SCHEMA_TRACING_PUBLIC.downstream_spans(_trace_id, _span_id, _max_dist) d
    WHERE d.dist != 0
$func$ LANGUAGE sql STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.span_tree(SCHEMA_TRACING_PUBLIC.trace_id, bigint, int) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.put_tag_key(_key SCHEMA_TRACING_PUBLIC.tag_k, _tag_type SCHEMA_TRACING_PUBLIC.tag_type)
RETURNS VOID
AS $func$
    INSERT INTO SCHEMA_TRACING.tag_key AS k (key, tag_type)
    VALUES (_key, _tag_type)
    ON CONFLICT (key) DO
    UPDATE SET tag_type = k.tag_type | EXCLUDED.tag_type
    WHERE k.tag_type & EXCLUDED.tag_type = 0
$func$
LANGUAGE SQL VOLATILE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.put_tag_key(SCHEMA_TRACING_PUBLIC.tag_k, SCHEMA_TRACING_PUBLIC.tag_type) TO prom_writer;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.put_tag(_key SCHEMA_TRACING_PUBLIC.tag_k, _value SCHEMA_TRACING_PUBLIC.tag_v, _tag_type SCHEMA_TRACING_PUBLIC.tag_type)
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
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.put_tag(SCHEMA_TRACING_PUBLIC.tag_k, SCHEMA_TRACING_PUBLIC.tag_v, SCHEMA_TRACING_PUBLIC.tag_type) TO prom_writer;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.jsonb(_tag_map SCHEMA_TRACING_PUBLIC.tag_map)
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
        -- filter on a.key to eliminate all but one partition of the tag table
        AND a.key = (SELECT k.key from SCHEMA_TRACING.tag_key k WHERE k.id = x.key::bigint)
        LIMIT 1
    ) a on (true)
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.jsonb(SCHEMA_TRACING_PUBLIC.tag_map) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.jsonb(_tag_map SCHEMA_TRACING_PUBLIC.tag_map, VARIADIC _keys SCHEMA_TRACING_PUBLIC.tag_k[])
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
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.jsonb(SCHEMA_TRACING_PUBLIC.tag_map) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.val(_tag_map SCHEMA_TRACING_PUBLIC.tag_map, _key SCHEMA_TRACING_PUBLIC.tag_k)
RETURNS SCHEMA_TRACING_PUBLIC.tag_v
AS $func$
    SELECT a.value
    FROM SCHEMA_TRACING.tag a
    WHERE a.key = _key -- partition elimination
    AND a.id = (_tag_map->>(SELECT id::text FROM SCHEMA_TRACING.tag_key WHERE key = _key))::bigint
    LIMIT 1
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.val(SCHEMA_TRACING_PUBLIC.tag_map, SCHEMA_TRACING_PUBLIC.tag_k) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.val_text(_tag_map SCHEMA_TRACING_PUBLIC.tag_map, _key SCHEMA_TRACING_PUBLIC.tag_k)
RETURNS text
AS $func$
    SELECT a.value#>>'{}'
    FROM SCHEMA_TRACING.tag a
    WHERE a.key = _key -- partition elimination
    AND a.id = (_tag_map->>(SELECT id::text FROM SCHEMA_TRACING.tag_key WHERE key = _key))::bigint
    LIMIT 1
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.val_text(SCHEMA_TRACING_PUBLIC.tag_map, SCHEMA_TRACING_PUBLIC.tag_k) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.get_tag_map(_tags jsonb)
RETURNS SCHEMA_TRACING_PUBLIC.tag_map
AS $func$
    SELECT coalesce(jsonb_object_agg(a.key_id, a.id), '{}')::SCHEMA_TRACING_PUBLIC.tag_map
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
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.get_tag_map(jsonb) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.tag_key_id(_key SCHEMA_TRACING_PUBLIC.tag_k)
RETURNS text
AS $func$
    SELECT k.id::text
    FROM SCHEMA_TRACING.tag_key k
    WHERE k.key = _key
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.tag_key_id(SCHEMA_TRACING_PUBLIC.tag_k) TO prom_reader;

CREATE OR REPLACE FUNCTION SCHEMA_TRACING_PUBLIC.tag_key_ids(VARIADIC _keys SCHEMA_TRACING_PUBLIC.tag_k[])
RETURNS text[]
AS $func$
    SELECT array_agg(k.id::text)
    FROM SCHEMA_TRACING.tag_key k
    WHERE k.key = ANY(_keys)
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION SCHEMA_TRACING_PUBLIC.tag_key_ids(SCHEMA_TRACING_PUBLIC.tag_k[]) TO prom_reader;
