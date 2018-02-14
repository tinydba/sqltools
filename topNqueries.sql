/* 
================================================================================
 Author     : TinyDBA (tinydba@gmail.com)
 Create date: 20/10/2017
 Description: The purpose of this code is to create objects (tables, procedures
              and jobs) that will help in capturing top queries running in an
              Oracle database. Capture is based on GV$SQL_MONITOR view, which
              monitors any query that is either running in parallel or it has
              duration longer than 5 seconds. After capturing top N queries
              it generates immediately SQL Monitor reports for all queries
              captured and stores them in a table for later viewing and analysis.
 Requirments: Schema where the objects will becreated should have following
              privileges:
              + CREATE TABLE
              + CREATE PROCEDURE
              + CREATE JOB
              + SELECT ANY DICTIONARY
              + EXECUTE on DBMS_XPLAN
              Although the user has a system privilege SELECT ANY DICTIONARY
              there is no need to grant CREATE SESSION to this schema, instead
              we can give other user SELECT privileges on this user tables.
  Credits   : Exception handling code taken from Error Management article by
              Steven Feuerstein in TECHNOLOGY: PL/SQL section of Oracle Magazine March/April 2012
              http://www.oracle.com/technetwork/issue-archive/2012/12-mar/o22plsql-1518275.html
              It has been slightly changed and adopted to my needs.
================================================================================
*/

/*
    ========================= SCHEMA CREATION SECTION =========================
*/
SET VERIFY OFF

DEFINE SCHEMA                 = 'U_TOPNSQLM' -- Name of the schema where the objects will be created
DEFINE PASSWORD               = 'welcome1'
DEFINE DEFAULT_TABLESPACE     = 'T_TOPNSQLM'
DEFINE TEMPORARY_TABLESPACE   = 'TEMP'
DEFINE DATAFILE               = '/u01/oradata/t_topnsqlm01.dbf'
DEFINE TOP_N_QUERIES          = '5' -- The limit of top n queries to collect from GV$SQL_MONITOR
DEFINE REPORT_RETENTION       = '45' -- Generated SQL Monitor reports retention period in days
DEFINE ARCHIVAL_CUTOFF        = '10' -- A period in days after which data from monitoring table is archived
DEFINE MONITORING_TABLE       = 'TBL_MONITOR' -- Into this table top n queries will be collected from GV$SQL_MONITOR
DEFINE MONITORING_TABLE_H     = 'TBL_MONITOR_H' -- Name of the archival table of monitoring data
DEFINE REPORTS_TABLE          = 'TBL_REPORTS' -- Here is where we save the generated reports
DEFINE OPERATION_LOG_TABLE    = 'TBL_OPERATION_LOG' -- Here we log the time, operation type and number of records processed
DEFINE ERROR_LOG_TABLE        = 'TBL_ERROR_LOG' -- Any errors thrown during report generation will be saved here
DEFINE COLLECT_PROCEDURE      = 'PRD_COLLECT_TOP_QUERIES' -- Name of the collection procedure
DEFINE PURGE_PROCEDURE        = 'PRD_PURGE_OLD_REPORTS' -- Name of the purge reports procedure
DEFINE ARCHIVE_PROCEDURE      = 'PRD_ARCHIVE_MONITOR_DATA' -- Archival procedure for monitoring data
DEFINE RECORD_ERROR_PROCEDURE = 'PRD_RECORD_ERROR' -- Name of the error recording procedure
DEFINE COLLECT_JOB_NAME       = 'JOB_COLLECT_TOP_QUERIES' -- Name of the collection job
DEFINE COLLECT_INTERVAL       = 'FREQ=MINUTELY;INTERVAL=30' -- Collection job interval
DEFINE COLLECT_START_DATE     = "2018-01-11 12:00:00.000000000 EUROPE/PARIS','YYYY-MM-DD HH24:MI:SS.FF TZR" -- Collection job start date
DEFINE COLLECT_END_DATE       = "2020-01-11 14:00:00.000000000 EUROPE/PARIS','YYYY-MM-DD HH24:MI:SS.FF TZR" -- Collection job end date
DEFINE PURGE_JOB_NAME         = 'JOB_PURGE_OLD_REPORTS' -- Name of the purge reports job
DEFINE PURGE_INTERVAL         = 'FREQ=DAILY;BYTIME=010000' -- Purge reports job interval
DEFINE PURGE_START_DATE       = "2018-01-12 01:00:00.000000000 EUROPE/PARIS','YYYY-MM-DD HH24:MI:SS.FF TZR" -- Purge reports job start date
DEFINE PURGE_END_DATE         = "2020-01-11 23:59:59.000000000 EUROPE/PARIS','YYYY-MM-DD HH24:MI:SS.FF TZR" -- Purge reports job end date
DEFINE ARCHIVAL_JOB_NAME      = 'JOB_ARCHIVE_MONITOR_DATA' -- Archival job name
DEFINE ARCHIVAL_INTERVAL      = 'FREQ=DAILY;BYTIME=010000' -- Archival job interval
DEFINE ARCHIVAL_START_DATE    = "2018-01-12 01:30:00.000000000 EUROPE/PARIS','YYYY-MM-DD HH24:MI:SS.FF TZR" -- Archival job start date
DEFINE ARCHIVAL_END_DATE      = "2020-01-11 23:59:59.000000000 EUROPE/PARIS','YYYY-MM-DD HH24:MI:SS.FF TZR" -- Archival job end date

CREATE SMALLFILE TABLESPACE &&DEFAULT_TABLESPACE
DATAFILE &&DATAFILE
SIZE 128M REUSE AUTOEXTEND ON NEXT 128M MAXSIZE 4096M
LOGGING EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO;

DROP USER &&SCHEMA CASCADE;

CREATE USER &&SCHEMA IDENTIFIED BY "&&PASSWORD"
DEFAULT TABLESPACE &&DEFAULT_TABLESPACE
TEMPORARY TABLESPACE &&TEMPORARY_TABLESPACE;
ALTER USER &&SCHEMA QUOTA UNLIMITED ON &&DEFAULT_TABLESPACE;

GRANT CREATE TABLE, CREATE PROCEDURE, CREATE JOB TO &&SCHEMA;
GRANT SELECT ANY DICTIONARY TO &&SCHEMA;
GRANT EXECUTE ON DBMS_XPLAN TO &&SCHEMA;

/*
    ========================= DEPLOYMENT SECTION =========================
*/

/*
    This table is a subset of attributes from the view GV$SQL_MONITOR.
    It is filled with top queries from that view in regular time intervals,
    preferably before records are aged out of the buffer.
*/
CREATE TABLE &&SCHEMA..&&MONITORING_TABLE (
      SNAPTIME               DATE
    , KEY                    NUMBER
    , STATUS                 VARCHAR2(19 CHAR)
    , USERNAME               VARCHAR2(30 CHAR)
    , MODULE                 VARCHAR2(64 CHAR)
    , ACTION                 VARCHAR2(64 CHAR)
    , SERVICE_NAME           VARCHAR2(64 CHAR)
    , CLIENT_IDENTIFIER      VARCHAR2(64 CHAR)
    , PROGRAM                VARCHAR2(48 CHAR)
    , SID                    NUMBER
    , SESSION_SERIAL#        NUMBER
    , SQL_ID                 VARCHAR2(13 CHAR)
    , SQL_EXEC_START         DATE
    , SQL_EXEC_ID            NUMBER
    , ELAPSED_TIME           NUMBER
    , CPU_TIME               NUMBER
    , BUFFER_GETS            NUMBER
    , RM_CONSUMER_GROUP      VARCHAR2(30 CHAR)
    , PX_MAXDOP              NUMBER
    , USER_IO_WAIT_TIME      NUMBER
    , PHYSICAL_READ_REQUESTS NUMBER
    , SQL_TEXT               VARCHAR2(2000 CHAR)
);

/*
    This table archives the data from MONITORING_TABLE to preserve basic performance data
    for its posterior analysis.
*/
CREATE TABLE &&SCHEMA..&&MONITORING_TABLE_H (
      SNAPTIME               DATE
    , KEY                    NUMBER
    , STATUS                 VARCHAR2(19 CHAR)
    , USERNAME               VARCHAR2(30 CHAR)
    , MODULE                 VARCHAR2(64 CHAR)
    , ACTION                 VARCHAR2(64 CHAR)
    , SERVICE_NAME           VARCHAR2(64 CHAR)
    , CLIENT_IDENTIFIER      VARCHAR2(64 CHAR)
    , PROGRAM                VARCHAR2(48 CHAR)
    , SID                    NUMBER
    , SESSION_SERIAL#        NUMBER
    , SQL_ID                 VARCHAR2(13 CHAR)
    , SQL_EXEC_START         DATE
    , SQL_EXEC_ID            NUMBER
    , ELAPSED_TIME           NUMBER
    , CPU_TIME               NUMBER
    , BUFFER_GETS            NUMBER
    , RM_CONSUMER_GROUP      VARCHAR2(30 CHAR)
    , PX_MAXDOP              NUMBER
    , USER_IO_WAIT_TIME      NUMBER
    , PHYSICAL_READ_REQUESTS NUMBER
    , SQL_TEXT               VARCHAR2(2000 CHAR)
);

/*
    This table saves the SQL Monitor reports generated from sql_id's saved to
    the &&MONITORING_TABLE table.
*/
CREATE TABLE &&SCHEMA..&&REPORTS_TABLE (
      SNAPTIME        DATE
    , SID             NUMBER
    , SESSION_SERIAL# NUMBER
    , SQL_ID          VARCHAR2(13 CHAR)
    , SQL_EXEC_START  DATE
    , SQL_EXEC_ID     NUMBER
    , REPORT          CLOB
);


/*
    The purpose of this table is to log the actions, their start and end times,
    to be able to calculate duration, what table was the object of the actions
    what action it was INSERT or DELETE, and how many records were affected by
    the action.
*/
CREATE TABLE &&SCHEMA..&&OPERATION_LOG_TABLE (
      START_TIME     TIMESTAMP
    , END_TIME       TIMESTAMP
    , TABLE_NAME     VARCHAR2(30 CHAR)
    , ROWS_PROCESSED NUMBER
    , ACTION         VARCHAR2(6 CHAR)
);

/*
    The purpose of this table is to record any arrors that ocurred during the 
    report generation phase.
*/
CREATE TABLE &&SCHEMA..&&ERROR_LOG_TABLE (
      ERROR_CODE    INTEGER
    , ERROR_MESSAGE VARCHAR2 (4000)
    , BACKTRACE     CLOB
    , CALLSTACK     CLOB
    , CREATED_ON    DATE
    , CREATED_BY    VARCHAR2 (30)
    , OBSERVATIONS  VARCHAR2(4000)
);

GRANT SELECT ON &&SCHEMA..&&MONITORING_TABLE TO con_bd_pro_oms;
GRANT SELECT ON &&SCHEMA..&&MONITORING_TABLE_H TO con_bd_pro_oms;
GRANT SELECT ON &&SCHEMA..&&REPORTS_TABLE TO con_bd_pro_oms;
GRANT SELECT ON &&SCHEMA..&&OPERATION_LOG_TABLE TO con_bd_pro_oms;
GRANT SELECT ON &&SCHEMA..&&ERROR_LOG_TABLE TO con_bd_pro_oms;

/*
    This procedure encapsulates logic for capturing errors.
*/
CREATE OR REPLACE PROCEDURE &&SCHEMA..&&RECORD_ERROR_PROCEDURE(p_comment VARCHAR2)
IS
   PRAGMA AUTONOMOUS_TRANSACTION;
   l_code  PLS_INTEGER     := SQLCODE;
   l_mesg  VARCHAR2(32767) := SQLERRM; 
BEGIN
    INSERT INTO &&ERROR_LOG_TABLE (ERROR_CODE
                             , ERROR_MESSAge
                             , BACKTRACE
                             , CALLSTACK
                             , CREATED_ON
                             , CREATED_BY
                             , OBSERVATIONS)
         VALUES (l_code
               , l_mesg 
               , sys.DBMS_UTILITY.format_error_backtrace
               , sys.DBMS_UTILITY.format_call_stack
               , SYSDATE
               , USER
               , p_comment);
 
    COMMIT;
END &&RECORD_ERROR_PROCEDURE;
/

/*
    This procedure captures top N queries and afterwars generates SQL Monitor
    reports for the just captured executions.
*/
CREATE OR REPLACE PROCEDURE &&SCHEMA..&&COLLECT_PROCEDURE AS

    l_start_time     &&OPERATION_LOG_TABLE..start_time%type;
    l_rows_processed &&OPERATION_LOG_TABLE..rows_processed%type;
    l_report         CLOB;             -- Container for generated SQL Monitor reports
    l_limit          PLS_INTEGER := &&TOP_N_QUERIES; -- Number of top queries we want to capture.

    CURSOR c_sentences_to_report IS
        SELECT SQL_ID, SQL_EXEC_START, SQL_EXEC_ID, SID, SESSION_SERIAL#
          FROM (SELECT SQL_ID, SQL_EXEC_START, SQL_EXEC_ID, SID, SESSION_SERIAL#
                  FROM &&MONITORING_TABLE
                 WHERE SNAPTIME > SYSDATE - INTERVAL '15' MINUTE
                 ORDER BY ELAPSED_TIME DESC)
         WHERE ROWNUM <= l_limit
        UNION
        SELECT SQL_ID, SQL_EXEC_START, SQL_EXEC_ID, SID, SESSION_SERIAL#
          FROM (SELECT SQL_ID, SQL_EXEC_START, SQL_EXEC_ID, SID, SESSION_SERIAL#
                  FROM &&MONITORING_TABLE
                 WHERE SNAPTIME > SYSDATE - INTERVAL '15' MINUTE
                 ORDER BY CPU_TIME DESC)
         WHERE ROWNUM <= l_limit
        UNION
        SELECT SQL_ID, SQL_EXEC_START, SQL_EXEC_ID, SID, SESSION_SERIAL#
          FROM &&MONITORING_TABLE
         WHERE SNAPTIME > SYSDATE - INTERVAL '15' MINUTE
           AND SQL_ID IN (SELECT SQL_ID
                            FROM DBA_HIST_COLORED_SQL
                         )
    ;

BEGIN
    -- Get the starting point
    SELECT SYSTIMESTAMP INTO l_start_time FROM DUAL;

    -- Query to capture top N queries by elapsed time from GV$SQL_MONITOR
    INSERT /*+ APPEND */ INTO &&SCHEMA..&&MONITORING_TABLE
    SELECT SYSDATE AS SNAPTIME
         , MON.KEY
         , MON.STATUS
         , MON.USERNAME
         , MON.MODULE
         , MON.ACTION
         , MON.SERVICE_NAME
         , MON.CLIENT_IDENTIFIER
         , MON.PROGRAM
         , MON.SID
         , MON.SESSION_SERIAL#
         , MON.SQL_ID
         , MON.SQL_EXEC_START
         , MON.SQL_EXEC_ID
         , MON.ELAPSED_TIME
         , MON.CPU_TIME
         , MON.BUFFER_GETS
         , MON.RM_CONSUMER_GROUP
         , MON.PX_MAXDOP
         , MON.USER_IO_WAIT_TIME
         , MON.PHYSICAL_READ_REQUESTS
         , MON.SQL_TEXT
      FROM GV$SQL_MONITOR MON
     WHERE MON.USERNAME IS NOT NULL
       AND MON.STATUS NOT IN ('QUEUED', 'EXECUTING')
       AND MON.KEY NOT IN (SELECT KEY FROM &&MONITORING_TABLE)
    ;

    l_rows_processed := SQL%ROWCOUNT;

    -- Loging time it took to capture top N queries
    INSERT INTO &&OPERATION_LOG_TABLE(START_TIME, END_TIME, TABLE_NAME, ROWS_PROCESSED, ACTION)
    VALUES(l_start_time, SYSTIMESTAMP, '&&MONITORING_TABLE', l_rows_processed, 'INSERT');

    COMMIT;

    -- Get the starting point
    SELECT SYSTIMESTAMP INTO l_start_time FROM DUAL;

    -- Initialize counter to 0
    l_rows_processed := 0;

    -- Inside the loop a SQL Monitor report is generated for every SQL_ID found.
    FOR i IN c_sentences_to_report LOOP
        BEGIN
            -- SQL Monitor report generation
            l_report := DBMS_SQLTUNE.report_sql_monitor(sql_id         => i.sql_id
                                                      , sql_exec_id    => i.sql_exec_id
                                                      , sql_exec_start => i.sql_exec_start
                                                      , session_id     => i.sid
                                                      , session_serial => i.session_serial#
                                                      , type           => 'ACTIVE'
                                                      , report_level   => 'ALL +PARALLEL +PLAN_HISTOGRAM');

            -- Report inserted into the table
            INSERT INTO &&REPORTS_TABLE (SNAPTIME, SID, SESSION_SERIAL#, SQL_ID, SQL_EXEC_START, SQL_EXEC_ID, REPORT)
            VALUES (SYSDATE, i.sid, i.session_serial#, i.sql_id, i.sql_exec_start, i.sql_exec_id, l_report);
        EXCEPTION
            WHEN OTHERS THEN
                -- If the exception is risen during the report generation the error is recorded into 
                -- &&ERROR_LOG_TABLE
                &&RECORD_ERROR_PROCEDURE(i.sid || '/' ||
                                         i.session_serial# || '/' ||
                                         i.sql_exec_id || '/' ||
                                         i.sql_exec_start || '/' ||
                                         i.sql_id ||  ' generated an error during report creation.');
                CONTINUE;
        END;
        -- Counter is incremented
        l_rows_processed := l_rows_processed + 1;

    END LOOP;

    -- Operation logging
    INSERT INTO &&OPERATION_LOG_TABLE(START_TIME, END_TIME, TABLE_NAME, ROWS_PROCESSED, ACTION)
    VALUES(l_start_time, SYSTIMESTAMP, '&&REPORTS_TABLE', l_rows_processed, 'INSERT');

    COMMIT;

END &&COLLECT_PROCEDURE;
/

/*
    This procedures purges old reports and reclaims space left by deleted LOBS.
*/
CREATE OR REPLACE PROCEDURE &&SCHEMA..&&PURGE_PROCEDURE AS

    l_start_time       &&OPERATION_LOG_TABLE..start_time%type;
    l_rows_deleted     &&OPERATION_LOG_TABLE..rows_processed%type;
    l_report_retention PLS_INTEGER := &&REPORT_RETENTION; -- Indicates retention period for the reports, in days.

BEGIN
    -- Get the starting point
    SELECT SYSTIMESTAMP INTO l_start_time FROM DUAL;

    -- Purge old reports according to report retention period
    DELETE FROM &&REPORTS_TABLE WHERE SNAPTIME < SYSDATE - l_report_retention;

    l_rows_deleted := SQL%ROWCOUNT;

    -- Operation logging
    INSERT INTO &&OPERATION_LOG_TABLE(START_TIME, END_TIME, TABLE_NAME, ROWS_PROCESSED, ACTION)
    VALUES(l_start_time, SYSTIMESTAMP, '&&REPORTS_TABLE', l_rows_deleted, 'DELETE');
    COMMIT;

    -- Space left by deleted LOBS is not claimed back automatically hence the command MOVE.
    EXECUTE IMMEDIATE 'ALTER TABLE &&REPORTS_TABLE MOVE';

END &&PURGE_PROCEDURE;
/

/*
    This procedures purges old reports and reclaims space left by deleted LOBS.
*/
CREATE OR REPLACE PROCEDURE &&SCHEMA..&&ARCHIVE_PROCEDURE AS
    TYPE t_rowid_tab IS TABLE OF ROWID;

    l_rowid_tab           t_rowid_tab;

    l_start_time       &&OPERATION_LOG_TABLE..start_time%type;
    l_rows_processed   &&OPERATION_LOG_TABLE..rows_processed%type;
    l_archival_cutoff  PLS_INTEGER := &&ARCHIVAL_CUTOFF; -- Indicates retention period for the reports, in days.

BEGIN
    -- Get the starting point
    SELECT SYSTIMESTAMP INTO l_start_time FROM DUAL;

    SELECT ROWID
      BULK COLLECT INTO l_rowid_tab
      FROM &&MONITORING_TABLE
     WHERE SNAPTIME < SYSDATE - l_archival_cutoff;

    INSERT /*+ APPEND */ INTO &&MONITORING_TABLE_H
    SELECT *
      FROM &&MONITORING_TABLE
     WHERE SNAPTIME < SYSDATE - l_archival_cutoff;

    l_rows_processed := SQL%ROWCOUNT;

    -- Operation logging
    INSERT INTO &&OPERATION_LOG_TABLE(START_TIME, END_TIME, TABLE_NAME, ROWS_PROCESSED, ACTION)
    VALUES(l_start_time, SYSTIMESTAMP, '&&MONITORING_TABLE_H', l_rows_processed, 'INSERT');
    COMMIT;

    -- Get the starting point
    SELECT SYSTIMESTAMP INTO l_start_time FROM DUAL;

    -- Purge old reports according to report retention period
    DELETE FROM &&MONITORING_TABLE WHERE SNAPTIME < SYSDATE - l_archival_cutoff;

    l_rows_processed := SQL%ROWCOUNT;

    -- Operation logging
    INSERT INTO &&OPERATION_LOG_TABLE(START_TIME, END_TIME, TABLE_NAME, ROWS_PROCESSED, ACTION)
    VALUES(l_start_time, SYSTIMESTAMP, '&&MONITORING_TABLE', l_rows_processed, 'DELETE');
    COMMIT;

    -- Space left by deleted LOBS is not claimed back automatically hence the command MOVE.
    EXECUTE IMMEDIATE 'ALTER TABLE &&MONITORING_TABLE MOVE';
    EXECUTE IMMEDIATE 'ALTER TABLE &&MONITORING_TABLE_H MOVE';

END &&ARCHIVE_PROCEDURE;
/

-- Following PL/SQL block creates job to capture top N queries
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
            job_name => '&&SCHEMA..&&COLLECT_JOB_NAME',
            job_type => 'STORED_PROCEDURE',
            job_action => '&&COLLECT_PROCEDURE',
            number_of_arguments => 0,
            start_date => TO_TIMESTAMP_TZ('&&COLLECT_START_DATE'),
            repeat_interval => '&&COLLECT_INTERVAL',
            end_date => TO_TIMESTAMP_TZ('&&COLLECT_END_DATE'),
            enabled => FALSE,
            auto_drop => FALSE,
            comments => 'Runs procedure &&COLLECT_PROCEDURE');  

    DBMS_SCHEDULER.SET_ATTRIBUTE( 
             name => '&&SCHEMA..&&COLLECT_JOB_NAME', 
             attribute => 'logging_level', value => DBMS_SCHEDULER.LOGGING_OFF);

    DBMS_SCHEDULER.enable(
             name => '&&SCHEMA..&&COLLECT_JOB_NAME');
END;
/

-- Following PL/SQL block creates job to purge old reports.
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
            job_name => '&&SCHEMA..&&PURGE_JOB_NAME',
            job_type => 'STORED_PROCEDURE',
            job_action => '&&PURGE_PROCEDURE',
            number_of_arguments => 0,
            start_date => TO_TIMESTAMP_TZ('&&PURGE_START_DATE'),
            repeat_interval => '&&PURGE_INTERVAL',
            end_date => TO_TIMESTAMP_TZ('&&PURGE_END_DATE'),
            enabled => FALSE,
            auto_drop => FALSE,
            comments => 'Runs procedure &&PURGE_PROCEDURE');

    DBMS_SCHEDULER.SET_ATTRIBUTE( 
             name => '&&SCHEMA..&&PURGE_JOB_NAME', 
             attribute => 'logging_level', value => DBMS_SCHEDULER.LOGGING_OFF);

    DBMS_SCHEDULER.enable(
             name => '&&SCHEMA..&&PURGE_JOB_NAME');
END;
/

-- 
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
            job_name => '&&SCHEMA..&&ARCHIVAL_JOB_NAME',
            job_type => 'STORED_PROCEDURE',
            job_action => '&&ARCHIVE_PROCEDURE',
            number_of_arguments => 0,
            start_date => TO_TIMESTAMP_TZ('&&ARCHIVAL_START_DATE'),
            repeat_interval => '&&ARCHIVAL_INTERVAL',
            end_date => TO_TIMESTAMP_TZ('&&ARCHIVAL_END_DATE'),
            enabled => FALSE,
            auto_drop => FALSE,
            comments => 'Runs procedure &&ARCHIVE_PROCEDURE');

    DBMS_SCHEDULER.SET_ATTRIBUTE( 
             name => '&&SCHEMA..&&ARCHIVAL_JOB_NAME', 
             attribute => 'logging_level', value => DBMS_SCHEDULER.LOGGING_OFF);

    DBMS_SCHEDULER.enable(
             name => '&&SCHEMA..&&ARCHIVAL_JOB_NAME');
END;
/
