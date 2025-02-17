USE sys;
DELIMITER $$

DROP FUNCTION IF EXISTS IFZERO$$

CREATE FUNCTION IFZERO(a INT, b INT)
RETURNS INT
DETERMINISTIC
RETURN IF(a = 0, b, a)$$

DROP FUNCTION IF EXISTS LOCATE2$$

CREATE FUNCTION LOCATE2(needle TEXT(10000), haystack TEXT(10000), offset INT)
RETURNS INT
DETERMINISTIC
RETURN IFZERO(LOCATE(needle, haystack, offset), LENGTH(haystack) + 1)$$

DROP FUNCTION IF EXISTS GTID_NORMALIZE$$

CREATE FUNCTION GTID_NORMALIZE(g TEXT(10000))
RETURNS TEXT(10000)
DETERMINISTIC
RETURN GTID_SUBTRACT(g, '')$$

DROP FUNCTION IF EXISTS  GTID_COUNT$$

CREATE FUNCTION GTID_COUNT(gtid_set TEXT(10000))
RETURNS INT
DETERMINISTIC
BEGIN
  DECLARE result BIGINT DEFAULT 0;
  DECLARE colon_pos INT;
  DECLARE next_dash_pos INT;
  DECLARE next_colon_pos INT;
  DECLARE next_comma_pos INT;
  SET gtid_set = GTID_NORMALIZE(gtid_set);
  SET colon_pos = LOCATE2(':', gtid_set, 1);
  WHILE colon_pos != LENGTH(gtid_set) + 1 DO
     SET next_dash_pos = LOCATE2('-', gtid_set, colon_pos + 1);
     SET next_colon_pos = LOCATE2(':', gtid_set, colon_pos + 1);
     SET next_comma_pos = LOCATE2(',', gtid_set, colon_pos + 1);
     IF next_dash_pos < next_colon_pos AND next_dash_pos < next_comma_pos THEN
       SET result = result +
         SUBSTR(gtid_set, next_dash_pos + 1,
                LEAST(next_colon_pos, next_comma_pos) - (next_dash_pos + 1)) -
         SUBSTR(gtid_set, colon_pos + 1, next_dash_pos - (colon_pos + 1)) + 1;
     ELSE
       SET result = result + 1;
     END IF;
     SET colon_pos = next_colon_pos;
  END WHILE;
  RETURN result;
END$$

DROP FUNCTION IF EXISTS gr_applier_queue_length $$
CREATE FUNCTION gr_applier_queue_length()
RETURNS INT
DETERMINISTIC
BEGIN
  RETURN (SELECT sys.gtid_count( GTID_SUBTRACT( (SELECT
Received_transaction_set FROM performance_schema.replication_connection_status
WHERE Channel_name = 'group_replication_applier' ), (SELECT
@@global.GTID_EXECUTED) )));
END$$

DROP FUNCTION IF EXISTS gr_member_in_primary_partition$$

CREATE FUNCTION gr_member_in_primary_partition()
RETURNS VARCHAR(3)
DETERMINISTIC
BEGIN
  RETURN (SELECT IF( MEMBER_STATE='ONLINE' AND ((SELECT COUNT(*) FROM
performance_schema.replication_group_members WHERE MEMBER_STATE != 'ONLINE') >=
((SELECT COUNT(*) FROM performance_schema.replication_group_members)/2) = 0),
'YES', 'NO' ) FROM performance_schema.replication_group_members JOIN
performance_schema.replication_group_member_stats USING(member_id)
          where performance_schema.replication_group_members.member_id=@@server_uuid);
END$$

DROP VIEW  IF EXISTS gr_member_routing_candidate_status$$

CREATE VIEW gr_member_routing_candidate_status AS
    SELECT 
        sys.gr_member_in_primary_partition() AS viable_candidate,
        IF((SELECT 
                    (SELECT 
                                GROUP_CONCAT(variable_value)
                            FROM
                                performance_schema.global_variables
                            WHERE
                                variable_name IN ('read_only' , 'super_read_only')) != 'OFF,OFF'
                ),
            'YES',
            'NO') AS read_only,
        sys.gr_applier_queue_length() AS transactions_behind,
        Count_Transactions_in_queue AS 'transactions_to_cert'
    FROM
        performance_schema.replication_group_member_stats a
            JOIN
        performance_schema.replication_group_members b ON a.member_id = b.member_id
    WHERE
        b.member_id IN (SELECT 
                variable_value
            FROM
                performance_schema.global_variables
            WHERE
                variable_name = 'server_uuid')$$

DELIMITER ;
