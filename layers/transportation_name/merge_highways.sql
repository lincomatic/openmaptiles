DROP TRIGGER IF EXISTS trigger_flag ON osm_highway_linestring;
DROP TRIGGER IF EXISTS trigger_refresh ON transportation_name.updates;

-- Instead of using relations to find out the road names we
-- stitch together the touching ways with the same name
-- to allow for nice label rendering
-- Because this works well for roads that do not have relations as well


-- etldoc: osm_highway_linestring ->  osm_transportation_name_network
-- etldoc: osm_route_member ->  osm_transportation_name_network
CREATE MATERIALIZED VIEW osm_transportation_name_network AS (
  SELECT
      hl.geometry,
      hl.osm_id,
      hl.name,
      hl.name_en,
      hl.name_de,
      rm.network_type,
      CASE
        WHEN (rm.network_type is not null AND nullif(rm.ref::text, '') is not null)
          then rm.ref::text
        else hl.ref
      end as ref,
      hl.highway,
      ROW_NUMBER() OVER(PARTITION BY hl.osm_id
                                   ORDER BY rm.network_type) AS "rank",
      hl.z_order
  FROM osm_highway_linestring hl
  left join osm_route_member rm on (rm.member = hl.osm_id)
);
CREATE INDEX IF NOT EXISTS osm_transportation_name_network_geometry_idx ON osm_transportation_name_network USING gist(geometry);


-- etldoc: osm_transportation_name_network ->  osm_transportation_name_linestring
CREATE MATERIALIZED VIEW osm_transportation_name_linestring AS (
    SELECT
        (ST_Dump(geometry)).geom AS geometry,
        -- NOTE: The osm_id is no longer the original one which can make it difficult
        -- to lookup road names by OSM ID
        member_osm_ids[1] AS osm_id,
        member_osm_ids,
        name,
        name_en,
        name_de,
        ref,
        highway,
        network_type AS network,
        z_order
    FROM (
      SELECT
          ST_LineMerge(ST_Collect(geometry)) AS geometry,
          name,
          name_en,
          name_de,
          ref,
          highway,
          network_type,
          min(z_order) AS z_order,
          array_agg(DISTINCT osm_id) AS member_osm_ids
      FROM osm_transportation_name_network
      WHERE ("rank"=1 OR "rank" is null)
        AND (name <> '' OR ref <> '')
        AND NULLIF(highway, '') IS NOT NULL
      group by name, name_en, name_de, ref, highway, network_type
    ) AS highway_union
);
CREATE INDEX IF NOT EXISTS osm_transportation_name_linestring_geometry_idx ON osm_transportation_name_linestring USING gist(geometry);

-- etldoc: osm_transportation_name_linestring -> osm_transportation_name_linestring_gen1
CREATE MATERIALIZED VIEW osm_transportation_name_linestring_gen1 AS (
    SELECT ST_Simplify(geometry, 50) AS geometry, osm_id, member_osm_ids, name, name_en, name_de, ref, highway, network, z_order
    FROM osm_transportation_name_linestring
    WHERE highway IN ('motorway','trunk')  AND ST_Length(geometry) > 8000
);
CREATE INDEX IF NOT EXISTS osm_transportation_name_linestring_gen1_geometry_idx ON osm_transportation_name_linestring_gen1 USING gist(geometry);

-- etldoc: osm_transportation_name_linestring_gen1 -> osm_transportation_name_linestring_gen2
CREATE MATERIALIZED VIEW osm_transportation_name_linestring_gen2 AS (
    SELECT ST_Simplify(geometry, 120) AS geometry, osm_id, member_osm_ids, name, name_en, name_de, ref, highway, network, z_order
    FROM osm_transportation_name_linestring_gen1
    WHERE highway IN ('motorway','trunk')  AND ST_Length(geometry) > 14000
);
CREATE INDEX IF NOT EXISTS osm_transportation_name_linestring_gen2_geometry_idx ON osm_transportation_name_linestring_gen2 USING gist(geometry);

-- etldoc: osm_transportation_name_linestring_gen2 -> osm_transportation_name_linestring_gen3
CREATE MATERIALIZED VIEW osm_transportation_name_linestring_gen3 AS (
    SELECT ST_Simplify(geometry, 200) AS geometry, osm_id, member_osm_ids, name, name_en, name_de, ref, highway, network, z_order
    FROM osm_transportation_name_linestring_gen2
    WHERE highway = 'motorway' AND ST_Length(geometry) > 20000
);
CREATE INDEX IF NOT EXISTS osm_transportation_name_linestring_gen3_geometry_idx ON osm_transportation_name_linestring_gen3 USING gist(geometry);

-- etldoc: osm_transportation_name_linestring_gen3 -> osm_transportation_name_linestring_gen4
CREATE MATERIALIZED VIEW osm_transportation_name_linestring_gen4 AS (
    SELECT ST_Simplify(geometry, 500) AS geometry, osm_id, member_osm_ids, name, name_en, name_de, ref, highway, network, z_order
    FROM osm_transportation_name_linestring_gen3
    WHERE highway = 'motorway' AND ST_Length(geometry) > 20000
);
CREATE INDEX IF NOT EXISTS osm_transportation_name_linestring_gen4_geometry_idx ON osm_transportation_name_linestring_gen4 USING gist(geometry);

-- Handle updates

CREATE SCHEMA IF NOT EXISTS transportation_name;

CREATE TABLE IF NOT EXISTS transportation_name.updates(id serial primary key, t text, unique (t));
CREATE OR REPLACE FUNCTION transportation_name.flag() RETURNS trigger AS $$
BEGIN
    INSERT INTO transportation_name.updates(t) VALUES ('y')  ON CONFLICT(t) DO NOTHING;
    RETURN null;
END;
$$ language plpgsql;

CREATE OR REPLACE FUNCTION transportation_name.refresh() RETURNS trigger AS
  $BODY$
  BEGIN
    RAISE LOG 'Refresh transportation_name';
    REFRESH MATERIALIZED VIEW osm_transportation_name_linestring;
    REFRESH MATERIALIZED VIEW osm_transportation_name_linestring_gen1;
    REFRESH MATERIALIZED VIEW osm_transportation_name_linestring_gen2;
    REFRESH MATERIALIZED VIEW osm_transportation_name_linestring_gen3;
    REFRESH MATERIALIZED VIEW osm_transportation_name_linestring_gen4;
    DELETE FROM transportation_name.updates;
    RETURN null;
  END;
  $BODY$
language plpgsql;

CREATE TRIGGER trigger_flag
    AFTER INSERT OR UPDATE OR DELETE ON osm_highway_linestring
    FOR EACH STATEMENT
    EXECUTE PROCEDURE transportation_name.flag();

CREATE CONSTRAINT TRIGGER trigger_refresh
    AFTER INSERT ON transportation_name.updates
    INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE PROCEDURE transportation_name.refresh();
