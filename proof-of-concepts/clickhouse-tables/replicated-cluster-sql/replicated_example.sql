CREATE TABLE events_local on cluster '{cluster}' (
    event_date  Date,
    event_type  Int32,
    article_id  Int32,
    title       String
) engine=ReplicatedMergeTree('/clickhouse/{installation}/{cluster}/tables/{shard}/{database}/{table}', '{replica}')
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_type, article_id);

CREATE TABLE events on cluster '{cluster}' AS events_local
ENGINE = Distributed('{cluster}', default, events_local, rand());

-- INSERT INTO events SELECT today(), rand()%3, number, 'my title' FROM numbers(100);