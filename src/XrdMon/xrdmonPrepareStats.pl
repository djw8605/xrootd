#!/usr/local/bin/perl -w

use DBI;

###############################################################################
#                                                                             #
#                             prepareMySQLStats.pl                            #
#                                                                             #
#  (c) 2005 by the Board of Trustees of the Leland Stanford, Jr., University  #
#                             All Rights Reserved                             #
#        Produced by Jacek Becla for Stanford University under contract       #
#               DE-AC02-76SF00515 with the Department of Energy               #
###############################################################################

# $Id$


use vars qw( @gmt $sec $min $hour $wday $sec2Sleep $loadTime);
## take care of arguments

if ( @ARGV == 2 ) {
    $configFile = $ARGV[0];
    $action = $ARGV[1];
} else {
    &printUsage('start', 'stop');
}

if ( $action eq 'stop' ) {
    &readConfigFile($configFile, 'prepare', 0);
    $stopFName = "$baseDir/$0";
    substr($stopFName,-2,2,'stop');
    `touch  $stopFName`;
    exit;
} elsif ( $action ne 'start') {
    &printUsage('start', 'stop');
}

# Start

&readConfigFile($configFile, 'prepare', 1);

# connect to the database
unless ( $dbh = DBI->connect("dbi:mysql:$dbName;mysql_socket=$mysqlSocket",$mySQLUser) ) {
    print "Error while connecting to database. $DBI::errstr\n";
    exit;
}
 
&initPrepare();

#start an infinite loop
while ( 1 ) {
    # wake up every minute at HH:MM:30
    @gmt   = gmtime(time());
    $sec2Sleep = $gmt[0] <= 30 ? 30 - $gmt[0] : 90 - $gmt[0];
    print "sleeping $sec2Sleep sec... \n";
    sleep $sec2Sleep;
 
    $loadTime = &timestamp();
    print "$loadTime\n";

    $loadTime = &gmtimestamp();
    foreach $siteName (@siteNames) {
        next if ( -e "$baseDir/$siteName/journal/inhibitPrepare" ); 
        if ( $firstCall{$siteName} ) {
            &initPrepare4OneSite($siteName);
            $firstCall{$siteName} = 0;
        }
        $dbUpdates{$siteName} = &runQueryWithRet("SELECT dbUpdate 
                                                    FROM sites 
                                                   WHERE name = '$siteName' ");
	&prepareStats4OneSite($siteName, $loadTime);
    }

    if ( -e $stopFName ) {
        print "Detected $stopFName. Exiting... \n";
	unlink $stopFName;
	exit;
    }
    # make sure the loop takes at least 2 s
    if ( $loadTime eq &gmtimestamp() ) {
        sleep 2;
    }
}


###############################################################################
###############################################################################
###############################################################################

sub avNumJobsInTimeInterval() {
    my ($t1, $t2, $interval, $siteName) = @_;

    if ( $t2 lt $firstDates{$siteName} ) {return(0);}
    print "sub avNumJobsInTimeInterval: $t1, $t2, $interval, $siteName \n";

    &runQuery("INSERT INTO times
                     SELECT GREATEST('$t1', beginT), LEAST('$t2', endT)
                       FROM ${siteName}_jobs
                      WHERE beginT < '$t2'         AND
                            endT   > '$t1'         AND
                            noOpenSessions = 0             ");
    print "Query 1 finished \n";
    &runQuery("INSERT INTO times
                     SELECT GREATEST('$t1', beginT), '$t2'
                       FROM ${siteName}_jobs
                      WHERE beginT < '$t2'         AND
                            noOpenSessions > 0             ");

    print "Query 2 finished \n";
    my $sumT = $interval *
               &runQueryWithRet("SELECT IFNULL(COUNT(*),0)
                                   FROM times
                                  WHERE begT = '$t1'  AND
                                        endT = '$t2'     ");

    $sumT += &runQueryWithRet("SELECT IFNULL(SUM(TIMESTAMPDIFF(SECOND,begT,endT)),0)
                                 FROM times
                                WHERE begT > '$t1'         OR
                                      endT <  '$t2'              ");
    &runQuery("DELETE FROM times");

    return (int ($sumT / $interval + .5 ));
}

sub avNumNonUniqueFilesInTimeInterval() {
    use vars qw( $closedFiles );
    my ($t1, $t2, $interval, $siteName, $cfPeriod) = @_;
    if ( $cfPeriod eq "All" ) { 
         $closedFiles = "${siteName}_closedFiles";
    } else {
         $closedFiles = "${siteName}_closedFiles_Last$cfPeriod";
    }
    if ( $t2 lt $firstDates{$siteName} ) {return(0);}
    print "sub avNumNonUniqueFilesInTimeInterval: $t1, $t2, $interval, $siteName \n";

    &runQuery("INSERT INTO times
                     SELECT GREATEST('$t1', openT), LEAST('$t2', closeT)
                       FROM $closedFiles
                      WHERE openT  < '$t2'         AND
                            closeT > '$t1'             ");
    print "Query 1 finished \n";

    &runQuery("INSERT INTO times
                     SELECT GREATEST('$t1', openT), '$t2'
                       FROM ${siteName}_openedFiles
                      WHERE openT < '$t2'         ");
    print "Query 2 finished \n";

    my $sumT = $interval *
               &runQueryWithRet("SELECT IFNULL(COUNT(*),0)
                                   FROM times
                                  WHERE begT = '$t1'  AND
                                        endT = '$t2'     ");

    $sumT += &runQueryWithRet("SELECT IFNULL(SUM(TIMESTAMPDIFF(SECOND,begT,endT)),0)
                                 FROM times
                                WHERE begT > '$t1'         OR
                                      endT <  '$t2'              ");
    &runQuery("DELETE FROM times");

    return (int ($sumT / $interval + .5 ));
}

sub avNumUniqueFilesInTimeInterval() {
    use vars qw( $closedFiles );
    my ($t1, $t2, $interval, $siteName, $cfPeriod) = @_;
    if ( $cfPeriod eq "All" ) { 
         $closedFiles = "${siteName}_closedFiles";
    } else {
         $closedFiles = "${siteName}_closedFiles_Last$cfPeriod";
    }

    if ( $t2 lt $firstDates{$siteName} ) {return(0);}
    print "sub avNumUniqueFilesInTimeInterval: $t1, $t2, $interval, $siteName \n";

    &runQuery("INSERT INTO id_times
                     SELECT pathId, GREATEST('$t1', openT), LEAST('$t2', closeT)
                       FROM $closedFiles
                      WHERE openT  < '$t2'         AND
                            closeT > '$t1'             ");
    print "Query 1 finished \n";

    &runQuery("INSERT INTO id_times
                     SELECT pathId, GREATEST('$t1', openT), '$t2'
                       FROM ${siteName}_openedFiles
                      WHERE openT < '$t2'              ");
    print "Query 2 finished \n";


    # find the file list in the time interval
    @pathIds = &runQueryRetArray("SELECT DISTINCT theId
                                    FROM id_times          ");



    foreach $pathId ( @pathIds ) {
        my @openTs =  &runQueryRetArray("SELECT begT
                                           FROM id_times
                                          WHERE theId = $pathId
                                       ORDER BY begT           ");

        my @closeTs = &runQueryRetArray("SELECT endT
                                           FROM id_times
                                          WHERE theId = $pathId
                                       ORDER BY begT           ");

        my $nFiles = @openTs;
        my $openT  = $openTs[0];
        my $closeT = $closeTs[0];
        if ( $nFiles == 1 or $closeTs[0] eq $t2 ) {
             &runQuery("INSERT INTO times
                             VALUES ('$openT', '$closeT') ");
             next;
        }

        my $n = 1;
        while ( $n < $nFiles ) {
            if ( $openTs[$n] le $closeT ) {
                 $closeT = $closeTs[$n];
            } else {
                 &runQuery("INSERT INTO times
                                 VALUES ('$openT', '$closeT') ");
                 $openT  = $openTs[$n];
                 $closeT = $closeTs[$n];
            }
            if ( $closeT eq $t2 or $n = $nFiles - 1) {
                 &runQuery("INSERT INTO times
                                 VALUES ('$openT', '$closeT') ");
                 last;
            }
            $n++;
        }
    }
    print "Query 3 finished \n";

    $sumT = &runQueryWithRet("SELECT IFNULL(SUM(TIMESTAMPDIFF(SECOND,begT,endT)), 0)
                                FROM times" );
    &runQuery("DELETE FROM id_times");
    &runQuery("DELETE FROM times");

    return (int ($sumT / $interval + .5 ));
}

sub avNumUsersInTimeInterval() {
    my ($t1, $t2, $interval, $siteName) = @_;

    if ( $t2 lt $firstDates{$siteName} ) {return(0);}
    print "sub avNumUsersInTimeInterval:$t1, $t2, $interval, $siteName \n";

    &runQuery("INSERT INTO id_times
                     SELECT userId, GREATEST('$t1', beginT), LEAST('$t2', endT)
                       FROM ${siteName}_jobs
                      WHERE beginT < '$t2'         AND
                            endT   > '$t1'         AND
                            noOpenSessions = 0             ");
    print "Query 1 finished \n";

    &runQuery("INSERT INTO id_times
                     SELECT userId, GREATEST('$t1', beginT), '$t2'
                       FROM ${siteName}_jobs
                      WHERE beginT < '$t2'         AND
                             noOpenSessions > 0             ");

    print "Query 2 finished \n";

    # find the user list in the time interval
    @userIds = &runQueryRetArray("SELECT DISTINCT theId
                                    FROM id_times           ");


    foreach $userId ( @userIds ) {
        my @beginTs = &runQueryRetArray("SELECT begT
                                           FROM id_times
                                          WHERE theId = $userId
                                       ORDER BY begT           ");

        my @endTs = &runQueryRetArray("SELECT endT
                                         FROM id_times
                                        WHERE theId = $userId
                                     ORDER BY begT           ");

        my $nJobs = @beginTs;
        my $beginT = $beginTs[0];
        my $endT   = $endTs[0];
        if ( $nJobs == 1 or $endTs[0] eq $t2 ) {
             &runQuery("INSERT INTO times
                             VALUES ('$beginT', '$endT') ");
             next;
        }

        my $n = 1;
        while ( $n < $nJobs ) {
            if ( $beginTs[$n] le $endT ) {
                 $endT = $endTs[$n];
            } else {
                 &runQuery("INSERT INTO times
                                 VALUES ('$beginT', '$endT') ");
                 $beginT = $beginTs[$n];
                 $endT   = $endTs[$n];
            }
            if ( $endT eq $t2 or $n = $nJobs - 1) {
                 &runQuery("INSERT INTO times
                                 VALUES ('$beginT', '$endT') ");
                 last;
            }
            $n++;
        }
    }
    print "Query 3 finished \n";

    $sumT = &runQueryWithRet("SELECT IFNULL(SUM(TIMESTAMPDIFF(SECOND,begT,endT)), 0)
                                FROM times" );
    &runQuery("DELETE FROM id_times");
    &runQuery("DELETE FROM times");

    return (int ($sumT / $interval + .5 ));
}

sub closeIdleSessions() {
    # closes opened sessions with no open files.
    # Assignments:
    # duration = MAX(closeT, connectT) - MIN(openT, connectT)
    # disconnectT = MAX(closeT, connectT)
    # status = I

    my ($siteName, $GMTnow, $loadLastTables ) = @_;

    &printNow("Closing idle sessions... ");

    my $cutOffDate = &runQueryWithRet("SELECT DATE_SUB('$GMTnow', INTERVAL $maxSessionIdleTime)");

    # make temporary table of open sessions with no open files.
    &runQuery("CREATE TEMPORARY TABLE os_no_of LIKE ${siteName}_openedSessions");
    my $noDone = &runQueryRetNum("INSERT INTO os_no_of
                                        SELECT os.*
                                          FROM        ${siteName}_openedSessions os
                                               LEFT JOIN
                                                      ${siteName}_openedFiles of
                                            ON     os.id = of.sessionId
                                         WHERE of.id IS NULL");
    if ( $noDone == 0 ) {
        &runQuery("DROP TABLE IF EXISTS os_no_of");
        return
    }

    &runQuery("CREATE TEMPORARY TABLE cs_no_of LIKE ${siteName}_closedSessions");
    # close sessions with closed files
    my $n_cs_cf = 
        &runQueryRetNum("INSERT 
                           INTO cs_no_of
                         SELECT os.id, jobId, userId, pId, clientHId, serverHId,
                                TIMESTAMPDIFF(SECOND, MIN(cf.openT), MAX(cf.closeT)),
                                MAX(cf.closeT) AS maxT,
                                'I'
                           FROM os_no_of os, ${siteName}_closedFiles cf
                          WHERE os.id = cf.sessionId
                       GROUP BY os.id
                         HAVING maxT < '$cutOffDate' ");

    # close sessions with no files
    my $n_cs_no_f =
        &runQueryRetNum("INSERT 
                           INTO cs_no_of
                         SELECT os.id, jobId, userId, pId, clientHId, serverHId, 0, connectT, 'I'
                           FROM     os_no_of os
                                LEFT JOIN
                                    ${siteName}_closedFiles cf
                                ON  os.id = cf.sessionId
                          WHERE cf.id IS NULL   AND
                                os.connectT < '$cutOffDate'     ");

    &updateForClosedSessions("cs_no_of", $siteName, $GMTnow, $loadLastTables);

    &runQuery("DROP TABLE IF EXISTS os_no_of");
    &runQuery("DROP TABLE IF EXISTS cs_no_of");
    print "closed $n_cs_cf sessions with closed and $n_cs_no_f with no files\n"; 
}
sub closeLongSessions() {
    # closes opened sessions with associated open files which were
    # opened for longer than x days.
    # Assignments:
    # disconnectT = MAX(open-file openT, closed-file closeT) 
    # duration = disconnectT - MIN(openT)                  
    # status = L

    my ($siteName, $GMTnow, $loadLastTables) = @_;

    &printNow("Closing long sessions... ");

    my $cutOffDate = &runQueryWithRet("SELECT DATE_SUB('$GMTnow', INTERVAL $maxConnectTime)");
    &runQuery("CREATE TEMPORARY TABLE IF NOT EXISTS cs LIKE ${siteName}_closedSessions");
    my $noDone =&runQueryRetNum("
                 INSERT IGNORE INTO cs
                 SELECT os.id, jobId, userId, pId, clientHId, serverHId,
                        TIMESTAMPDIFF(SECOND,
                                      LEAST(IFNULL(MIN(cf.openT),'3'),
                                            MIN(of.openT)           ),
                                      GREATEST(IFNULL(MAX(cf.closeT),'2'),
                                               MAX(of.openT)            )  ),
                        GREATEST(IFNULL(MAX(cf.closeT),'2'),
                                 MAX(of.openT) ),
                        'L'
                   FROM         (${siteName}_openedSessions os,
                                 ${siteName}_openedFiles of)
                        LEFT JOIN
                                 ${siteName}_closedFiles cf
                        ON       os.id = cf.sessionId
                  WHERE 	os.id       = of.sessionId        AND
                        os.connectT < '$cutOffDate'
               GROUP BY os.id");

    if ( $noDone > 0 ) {
        &updateForClosedSessions("cs", $siteName, $GMTnow, $loadLastTables);
    }
    &runQuery("DROP TABLE IF EXISTS cs");
    print "$noDone closed\n";
}


# closes opened files corresponding to closed sessions
sub closeOpenedFiles() {
    my ($siteName, $GMTnow, $loadLastTables) = @_;

    &printNow("Closing open files... ");
    &runQuery("CREATE TEMPORARY TABLE xcf like ${siteName}_closedFiles");

    # give it extra time: sometimes closeFile
    # info may arrive after the closeSession info
    # timeout on xrootd server is ~ 1min, so 10 min should suffice
    # This is the default value of $fileCloseWaitTime
    &runQuery("INSERT IGNORE INTO xcf
                 SELECT of.id,
                        of.sessionId,
                        of.pathId,
                        of.openT,
                        cs.disconnectT,
                        -1,
                        -1
                 FROM   ${siteName}_openedFiles of,
                        ${siteName}_closedSessions cs
                 WHERE  sessionId = cs.id    AND
                        disconnectT < DATE_SUB('$GMTnow', INTERVAL $fileCloseWaitTime)");

    &runQuery("INSERT IGNORE INTO ${siteName}_closedFiles
                           SELECT * 
                             FROM xcf");

    if ( $loadLastTables ) {
        foreach $period ( @periods ) {
            next if ( $period eq "Hour" );
            &runQuery("INSERT IGNORE INTO ${siteName}_closedFiles_Last$period
                       SELECT * 
                         FROM xcf 
                        WHERE closeT > DATE_SUB('$GMTnow', INTERVAL 1 $period)");

        }
    } else {
        &runQuery("INSERT IGNORE INTO closedFiles
                   SELECT * 
                    FROM xcf ");
    }
 
    my $noDone =&runQueryRetNum("DELETE FROM  ${siteName}_openedFiles
                                  USING ${siteName}_openedFiles, xcf
                                  WHERE ${siteName}_openedFiles.id = xcf.id");
    &runQuery("DROP TABLE xcf");
    print " $noDone closed\n";
}

sub fillStatsAllYearsMissingBins() {
    use vars qw( $sourceTabTmin $firstInsertTime $avNumJobs $avNumUsers $avNumUniqueFiles $avNumNonUniqueFiles $seqNo);
    my ($siteName, $loadTime) = @_; 

    # find the number of seq for this period and return if all are there
    my $lastInsertTime = &getLastInsertTime($loadTime, "AllYears");
    my $firstInsertTime = &getLastInsertTime($firstDates{$siteName}, "AllYears" );
    my $nSeqs = &runQueryWithRet("SELECT FLOOR(TIMESTAMPDIFF(WEEK,'$firstInsertTime','$lastInsertTime'))");
    if ( &runQueryWithRet("SELECT COUNT(*)
                             FROM ${siteName}_statsAllYears")
         == $nSeqs ) { return;}

    my $intervalSec = 7 * 86400;

    $sourceTabTmin = &runQueryWithRet("SELECT MIN(date) FROM ${siteName}_statsLastYear");
                                          
    my $t2 = $firstInsertTime;
    my $t1 = &runQueryWithRet("SELECT DATE_SUB('$t2', INTERVAL 1 WEEK)");
    
    # use full tables to get older statistics
    while ( $t2 le $dbUpdates{$siteName} ) {
        if ( ! &runQueryWithRet("SELECT date 
                                   FROM ${siteName}_statsAllYears 
                                  WHERE date = '$t2' ") ) {
        
            if ( $t1 lt $sourceTabTmin ) {
                # use full tables to get older statistics
                $avNumJobs = &avNumJobsInTimeInterval($t1, $t2, $intervalSec, $siteName);
                $avNumUsers = &avNumUsersInTimeInterval($t1, $t2, $intervalSec, $siteName);
                $avNumUniqueFiles = &avNumUniqueFilesInTimeInterval($t1, $t2, $intervalSec, $siteName, "All");
                $avNumNonUniqueFiles = &avNumNonUniqueFilesInTimeInterval($t1, $t2, $intervalSec, $siteName, "All");
            } else {
                # use stats table from previous period
                ($avNumJobs, $avNumUsers, $avNumUniqueFiles, $avNumNonUniqueFiles) =
                  &runQueryWithRet("SELECT AVG(noJobs), AVG(noUsers), AVG(noUniqueF), AVG(noNonUniqueF)
                                      FROM ${siteName}_statsLastYear
                                     WHERE date >  '$t1'      AND
                                           date <= '$t2'         ");
            }
            if ( $avNumJobs ) {
                &runQuery("INSERT IGNORE INTO ${siteName}_statsAllYears
                                VALUES ('$t2', $avNumJobs, $avNumUsers, $avNumUniqueFiles, $avNumNonUniqueFiles)");
            }
        }
        $t1 = $t2;
        $t2 = &runQueryWithRet("SELECT DATE_ADD('$t2', INTERVAL 1 WEEK)");
    }

}
sub fillStatsMissingBins() {
    use vars qw($sourceTable $firstInsertTime $avNumJobs $avNumUsers $avNumUniqueFiles $avNumNonUniqueFiles $seqNo);
    my ($siteName, $period, $loadTime) = @_; 

    my $interval = $intervals{$period};
    my $timeUnit = $timeUnits{$period};
    
    # find the number of seq for this period and return if all are there
    my $lastInsertTime = &getLastInsertTime($loadTime, $period);
    my $firstInsertTime = &runQueryWithRet("SELECT DATE_SUB('$lastInsertTime', INTERVAL 1 $period)");
    my $nSeqs = &runQueryWithRet("SELECT FLOOR(TIMESTAMPDIFF($timeUnit,'$firstInsertTime','$lastInsertTime')/$interval)");
    if ( &runQueryWithRet("SELECT COUNT(*)
                             FROM ${siteName}_statsLast$period")
         == $nSeqs ) { return;}

    my $intervalSec = $interval * $seconds{$timeUnit};

    if ( $period eq "Day" ) {
        $sourceTabTmin = "";
    } else {
        $sourceTable = "${siteName}_statsLast$sourcePeriods{$period}";
        $sourceTabTmin = &runQueryWithRet("SELECT MIN(date) FROM $sourceTable");
    }
                                          

    my $t2 = $firstInsertTime;
    my $t1 = &runQueryWithRet("SELECT DATE_SUB('$t2', INTERVAL $interval $timeUnit)");
    
    # use full tables to get older statistics
    while ( $t2 le $dbUpdates{$siteName} ) {
        $seqNo = &timeToSeqNo( $t2, $period );
        if ( ! &runQueryWithRet("SELECT date FROM ${siteName}_statsLast$period WHERE seqNo = $seqNo") ) {

            if ( $period eq "Day" or $t1 lt $sourceTabTmin ) {
                # use full tables to get older statistics
                $avNumJobs = &avNumJobsInTimeInterval($t1, $t2, $intervalSec, $siteName);
                $avNumUsers = &avNumUsersInTimeInterval($t1, $t2, $intervalSec, $siteName);
                $avNumUniqueFiles = &avNumUniqueFilesInTimeInterval($t1, $t2, $intervalSec, $siteName, $period);
                $avNumNonUniqueFiles = &avNumNonUniqueFilesInTimeInterval($t1, $t2, $intervalSec, $siteName, $period);
            } else {
                # use stats table from previous period
                ($avNumJobs, $avNumUsers, $avNumUniqueFiles, $avNumNonUniqueFiles) =
                  &runQueryWithRet("SELECT AVG(noJobs), AVG(noUsers), AVG(noUniqueF), AVG(noNonUniqueF)
                                      FROM $sourceTable
                                     WHERE date >  '$t1'      AND
                                           date <= '$t2'         ");
            }
            if ( $avNumJobs ) {
                &runQuery("REPLACE INTO ${siteName}_statsLast$period
                                 VALUES ($seqNo, '$t2', $avNumJobs, $avNumUsers, $avNumUniqueFiles, $avNumNonUniqueFiles)");
            }
        }
        $t1 = $t2;
        $t2 = &runQueryWithRet("SELECT DATE_ADD('$t2', INTERVAL $interval $timeUnit)");
    }
}
 
sub forceClose() {
    my ($siteName, $loadTime, $loadLastTables) = @_;
    if ( $loadTime ge $nextFileClose{$siteName} ) {
        &closeOpenedFiles($siteName, $loadTime, $loadLastTables);
        &runQuery("UPDATE sites
                   SET closeFileT = '$loadTime'
                   WHERE name = '$siteName'");
        $nextFileClose{$siteName} =  &runQueryWithRet("SELECT DATE_ADD('$loadTime', INTERVAL $closeFileInt)");
    }
    
     if ( $loadTime ge $nextIdleSessionClose{$siteName} ) {
        &closeIdleSessions($siteName, $loadTime, $loadLastTables);
        &runQuery("UPDATE sites
                   SET closeIdleSessionT = '$loadTime'
                   WHERE name = '$siteName'");
        $nextIdleSessionClose{$siteName} =  &runQueryWithRet("SELECT DATE_ADD('$loadTime', INTERVAL $closeIdleSessionInt)");
    }    
        
     if ( $loadTime ge $nextLongSessionClose{$siteName} ) {
        &closeLongSessions($siteName, $loadTime, $loadLastTables);
        &runQuery("UPDATE sites
                   SET closeLongSessionT = '$loadTime'
                   WHERE name = '$siteName'");
        $nextLongSessionClose{$siteName} =  &runQueryWithRet("SELECT DATE_ADD('$loadTime', INTERVAL $closeLongSessionInt)");
    }  
}
sub getLastInsertTime() {
    # calculates the nearest allowed insert time to reference (snapshot or load) time.
    use vars qw($hour $day);
    my ($referenceTime, $period) = @_;

    # zero the second for all periods
    my $sec = &runQueryWithRet("SELECT SECOND('$referenceTime')");
    my $lastInsertTime = &runQueryWithRet("SELECT DATE_SUB('$referenceTime', INTERVAL $sec SECOND)");

    # HH:MM:00
    if ( $period eq "Hour" ) {return($lastInsertTime);}

    # zero the minute for everything but "Day" where it is every 15 minutes
    my $min = &runQueryWithRet("SELECT MINUTE('$lastInsertTime')");

    if ( $period eq "Day" ) { 
         $min = $min % 15;
         # HH:00:00 | HH:15:00 | HH:30:00 | HH:45:00
         return( &runQueryWithRet("SELECT DATE_SUB('$lastInsertTime', INTERVAL $min MINUTE)"));
    }

    $lastInsertTime = &runQueryWithRet("SELECT DATE_SUB('$lastInsertTime', INTERVAL $min MINUTE)");
    # HH:00:00
    if ( $period eq "Week" ) {return($lastInsertTime);}

    # zero the hour for "Year" and "AllYears" and every 6 hours for "Month"
    if ( $period eq "Month" ) {
         $hour = &runQueryWithRet("SELECT HOUR('$lastInsertTime') % 6");
         # 00:00:00 | 06:00:00 | 12:00:00 | 18:00:00
         return( &runQueryWithRet("SELECT DATE_SUB('$lastInsertTime', INTERVAL $hour HOUR)"));
    } 

    $hour = &runQueryWithRet("SELECT HOUR('$lastInsertTime')");
    if ( $period eq "Year" ) {
    # 00:00:00
    return( &runQueryWithRet("SELECT DATE_SUB('$lastInsertTime', INTERVAL $hour HOUR)"));
    }
    
    
    # zero the day for "AllYears"
    if ( $period eq "AllYears" ) {
         $lastInsertTime = &runQueryWithRet("SELECT DATE_SUB('$lastInsertTime', INTERVAL $hour HOUR)");
         $day = &runQueryWithRet("SELECT WEEKDAY('$lastInsertTime')+1 ");
         # Sunday 00:00:00
         return( &runQueryWithRet("SELECT DATE_SUB('$lastInsertTime', INTERVAL $day DAY)"));
    }
}
sub gmtimestamp() {
    my @gmt   = gmtime(time());
    my $sec   = $gmt[0];
    my $min   = $gmt[1];
    my $hour  = $gmt[2];
    my $day   = $gmt[3];
    my $month = $gmt[4] + 1;
    my $year  = $gmt[5] + 1900;

    return sprintf("%04d-%02d-%02d %02d:%02d:%02d", 
                   $year, $month, $day, $hour, $min, $sec);
}
sub initPrepare() {
    my $theTime = &timestamp();
    print "$theTime General initialization started \n";
    @periods = ( 'Hour', 'Day', 'Week', 'Month');
    %sourcePeriods = ('Week' => 'Day' , 'Month' => 'Week' , 'Year' => 'Month' , 'AllYears' => 'Year' );
    %intervals  = ('Hour' => 1        , 'Day' => 15       , 'Week' => 1      , 'Month' => 6      , 'Year' => 1     );
    %timeUnits  = ('Hour' => 'MINUTE' , 'Day' => 'MINUTE' , 'Week' => 'HOUR' , 'Month' => 'HOUR' , 'Year' => 'DAY' );
    %seconds    = ('MINUTE' => 60 , 'HOUR' => 3600 , 'DAY' => 86400 );
    $nFileTypes = &runQueryWithRet("SELECT COUNT(*) FROM fileTypes");

    $stopFName = "$baseDir/$0";
    substr($stopFName,-2,2,'stop');
    if ( -e $stopFName ) {
       unlink $stopFName;
    }

    @siteNames = &runQueryRetArray("SELECT name FROM sites");
    foreach $siteName (@siteNames) {
        $firstCall{$siteName} = 1;
    }

    # create temporary tables for topPerformers
    &runQuery("CREATE TEMPORARY TABLE jj  (theId INT, n INT, INDEX (theId))");
    &runQuery("CREATE TEMPORARY TABLE ff  (theId INT, n INT, s INT, INDEX (theId))");
    &runQuery("CREATE TEMPORARY TABLE uu  (theId INT, n INT, INDEX (theId))");
    &runQuery("CREATE TEMPORARY TABLE vv  (theId INT, n INT, INDEX (theId))");
    &runQuery("CREATE TEMPORARY TABLE xx  (theId INT UNIQUE KEY, INDEX (theId))");
    @topPerfTables = ("jj", "ff", "uu", "vv", "xx");

    # create temporary tables for stats
    &runQuery("CREATE TEMPORARY TABLE times (begT DATETIME NOT NULL, endT DATETIME NOT NULL,
                                            INDEX (begT), INDEX(endT) )");
    &runQuery("CREATE TEMPORARY TABLE id_times ( theId MEDIUMINT UNSIGNED NOT NULL,
                                            begT DATETIME NOT NULL, endT DATETIME NOT NULL,
                                            INDEX(theId), INDEX (begT), INDEX(endT) )");
    # cleanup old entries
    $GMTnow = &gmtimestamp();
    foreach $siteName (@sites) {
        &runQuery("DELETE FROM ${siteName}_statsLastHour  WHERE date <= DATE_SUB('$GMTnow', INTERVAL 1 HOUR)");
        &runQuery("DELETE FROM ${siteName}_statsLastDay   WHERE date <= DATE_SUB('$GMTnow', INTERVAL 1 DAY)");
        &runQuery("DELETE FROM ${siteName}_statsLastWeek  WHERE date <= DATE_SUB('$GMTnow', INTERVAL 1 WEEK)");
        &runQuery("DELETE FROM ${siteName}_statsLastMonth WHERE date <= DATE_SUB('$GMTnow', INTERVAL 1 MONTH)");
    }
    if ( $yearlyStats ) {
        push @periods, "Year";
        foreach $siteName (@sites) {
            &runQuery("DELETE FROM ${siteName}_statsLastYear  WHERE date <= DATE_SUB('$GMTnow', INTERVAL 1 YEAR)");
        }
    }
    $theTime = &timestamp();
    print "$theTime General initialization ended \n";
}
sub initPrepare4OneSite() {
    my ($siteName) = @_;
    my $theTime = &timestamp();
    print "$theTime Initialization started for $siteName  \n";

    ($nextFileClose{$siteName}, $nextIdleSessionClose{$siteName}, $nextLongSessionClose{$siteName}) = 
                    &runQueryWithRet("SELECT DATE_ADD(closeFileT, INTERVAL $closeFileInt),
                                             DATE_ADD(closeIdleSessionT, INTERVAL $closeIdleSessionInt),
                                             DATE_ADD(closeLongSessionT, INTERVAL $closeLongSessionInt)
                                        FROM sites
                                       WHERE name = '$siteName' ");

    # fill in missing points in statsLast tables
    $siteId = &runQueryWithRet("SELECT id 
                                  FROM sites 
                                 WHERE name = '$siteName'");
    $siteIds{$siteName} = $siteId;
    $dbUpdates{$siteName} = &runQueryWithRet("SELECT dbUpdate 
                                               FROM sites 
                                              WHERE name = '$siteName' ");
    $firstDates{$siteName} = &runQueryWithRet("SELECT firstDate
                                                 FROM sites 
                                                WHERE name = '$siteName' ");      
  
    # fill out missing bins in stats tables except for LastHour
    foreach $period ( @periods ) {
        next if ( $period eq "Hour" );
        &fillStatsMissingBins($siteName, $period, $GMTnow);
    }
    if ( $allYearsStats ) {
        &fillStatsAllYearsMissingBins($siteName, $GMTnow);
    }  
    # initialize lastNo... values
    $lastTime = &runQueryWithRet("SELECT MAX(date) FROM ${siteName}_statsLastHour");

    if ( $lastTime ) {
	 ($lastNoJobs[$siteId],    $lastNoUsers[$siteId], 
         $lastNoUniqueF[$siteId], $lastNoNonUniqueF[$siteId]) 
	 = &runQueryWithRet("SELECT noJobs,noUsers,noUniqueF,noNonUniqueF
                               FROM ${siteName}_statsLastHour 
                              WHERE date   = '$lastTime' ");
    } else { 
         $lastNoJobs[$siteId]=$lastNoUsers[$siteId]=0;
         $lastNoUniqueF[$siteId]=$lastNoNonUniqueF[$siteId]=0;
    }
    $theTime = &timestamp();
    print "$theTime Initialization ended for $siteName \n";
}
sub loadStatsAllYears() {
    my ($siteName, $loadTime) = @_;
    if ( &getLastInsertTime($loadTime, "AllYears") gt $dbUpdates{$siteName} ) {return;}

    my ($noJobs, $noUsers, $noUniqueF, $noNonUniqueF) 
      = &runQueryWithRet("SELECT AVG(noJobs), AVG(noUsers), AVG(noUniqueF), AVG(noNonUniqueF) 
                          FROM   ${siteName}_statsLastWeek"); 
    if ( $noJobs ) {
        &runQuery("INSERT IGNORE INTO ${siteName}_statsAllYears
                              (date, noJobs, noUsers, noUniqueF, noNonUniqueF) 
                        VALUES ('$loadTime', $noJobs, $noUsers,
                                $noUniqueF, $noNonUniqueF)");
    }
}
sub loadStatsLastHour() {
    my ($siteName, $loadTime, $seqNo) = @_;
    my $siteId = $siteIds{$siteName};
    use vars qw($noJobs $noUsers $noUniqueF $noNonUniqueF $deltaJobs $jobs_p 
                $deltaUsers $users_p $deltaUniqueF $uniqueF_p $deltaNonUniqueF $nonUniqueF_p);

    if ( &getLastInsertTime($loadTime, "Hour") gt $dbUpdates{$siteName} ) {return;}
    
    &runQuery("DELETE FROM ${siteName}_statsLastHour 
                     WHERE date < DATE_SUB('$loadTime', INTERVAL  1 HOUR)");

    ($noJobs, $noUsers) = &runQueryWithRet("SELECT COUNT(DISTINCT jobId), COUNT(DISTINCT userId) 
                                              FROM ${siteName}_openedSessions");

    ($noUniqueF, $noNonUniqueF) = &runQueryWithRet("SELECT COUNT(DISTINCT pathId), COUNT(*) 
                                                      FROM ${siteName}_openedFiles");
    &runQuery("REPLACE INTO ${siteName}_statsLastHour 
                      (seqNo, date, noJobs, noUsers, noUniqueF, noNonUniqueF) 
               VALUES ($seqNo, '$loadTime', $noJobs, $noUsers, $noUniqueF, $noNonUniqueF)");

    $deltaJobs = $noJobs - $lastNoJobs[$siteId]; 
    $jobs_p = $lastNoJobs[$siteId] > 0 ? &roundoff( 100 * $deltaJobs / $lastNoJobs[$siteId] ) : -1;
    $deltaUsers = $noUsers - $lastNoUsers[$siteId];
    $users_p = $lastNoUsers[$siteId] > 0 ? &roundoff( 100 * $deltaUsers / $lastNoUsers[$siteId] ) : -1;
    $deltaUniqueF = $noUniqueF - $lastNoUniqueF[$siteId];
    $uniqueF_p = $lastNoUniqueF[$siteId] > 0 ? &roundoff( 100 * $deltaUniqueF / $lastNoUniqueF[$siteId] ) : -1;
    $deltaNonUniqueF = $noNonUniqueF - $lastNoNonUniqueF[$siteId];
    $nonUniqueF_p = $lastNoNonUniqueF[$siteId] > 0 ? &roundoff( 100 * $deltaNonUniqueF / $lastNoNonUniqueF[$siteId] ) : -1;
    &runQuery("REPLACE INTO rtChanges 
                           (siteId, jobs, jobs_p, users, users_p, uniqueF, uniqueF_p, 
                            nonUniqueF, nonUniqueF_p, lastUpdate)
                    VALUES ($siteId, $deltaJobs, $jobs_p, $deltaUsers, $users_p, $deltaUniqueF,
                            $uniqueF_p, $deltaNonUniqueF, $nonUniqueF_p, '$loadTime')");
    $lastNoJobs[$siteId]       = $noJobs;
    $lastNoUsers[$siteId]      = $noUsers;
    $lastNoUniqueF[$siteId]    = $noUniqueF;
    $lastNoNonUniqueF[$siteId] = $noNonUniqueF;
}

sub loadStatsLastPeriod() {
    use vars qw($noJobs   $noUsers   $noUniqueF   $noNonUniqueF $nSeqs);
    my ($siteName, $loadTime, $period, $cfPeriod) = @_;
    my $interval = $intervals{$period};
    my $timeUnit = $timeUnits{$period};
    my $intervalSec = $interval * $seconds{$timeUnit};

    # $t1 - $t2 define the latest interval for $period
    my $t2 = &getLastInsertTime($loadTime, $period);

    # make sure db is loaded up to $t2
    if ( $t2 gt $dbUpdates{$siteName} ) {return;}

    my $t1 = &runQueryWithRet("SELECT DATE_SUB('$t2', INTERVAL $interval $timeUnit)");
    if ( $period eq "Day" ) { 
        # use long method for Day       
        $avNumJobs = &avNumJobsInTimeInterval($t1, $t2, $intervalSec, $siteName);
        $avNumUsers = &avNumUsersInTimeInterval($t1, $t2, $intervalSec, $siteName);
        $avNumUniqueFiles = &avNumUniqueFilesInTimeInterval($t1, $t2, $intervalSec, $siteName, $cfPeriod);
        $avNumNonUniqueFiles = &avNumNonUniqueFilesInTimeInterval($t1, $t2, $intervalSec, $siteName, $cfPeriod);
    } else {
        # use average from statsLastDay but first make sure all needed points exist.
        $nSeqs = &runQueryWithRet("SELECT FLOOR(TIMESTAMPDIFF(MINUTE,'$t1','$t2')/15)");
        if ( $nSeqs > &runQueryWithRet("SELECT COUNT(*)
                                                FROM ${siteName}_statsLastDay
                                               WHERE date >  '$t1'   AND
                                                     date <= '$t2'       ") ) {
             &fillStatsMissingBins($siteName,"Day",$loadTime);
        }
        ($avNumJobs, $avNumUsers, $avNumUniqueFiles, $avNumNonUniqueFiles) =
              &runQueryWithRet("SELECT AVG(noJobs), AVG(noUsers), AVG(noUniqueF), AVG(noNonUniqueF)
                                  FROM ${siteName}_statsLastDay
                                 WHERE date >  '$t1'      AND
                                       date <= '$t2'         ");
    }
    if ( $avNumJobs ) {
        $seqNo = &timeToSeqNo( $t2, $period );
        &runQuery("REPLACE INTO ${siteName}_statsLast$period
                    VALUES ($seqNo, '$t2', $avNumJobs, $avNumUsers, $avNumUniqueFiles, $avNumNonUniqueFiles)");
    }
}
sub loadTopPerfNow() {
    my ($theLimit, $siteName) = @_;

    &runTopUsersQueriesNow($theLimit, $siteName);
    foreach $table (@topPerfTables) { &runQuery("DELETE FROM $table"); }
    for  $tId ( 1 .. $nFileTypes ) {
        &runTopTypeQueriesNow($theLimit, $tId, $siteName);
        foreach $table (@topPerfTables) { &runQuery("DELETE FROM $table"); }
    }
    &runTopFilesQueriesNow($theLimit, $siteName);
    foreach $table (@topPerfTables) { &runQuery("DELETE FROM $table"); }
}
sub loadTopPerfPast() {
    my ($period, $theLimit, $siteName, $loadTime) = @_;

    &runTopUsersQueriesPast($period, $theLimit, $siteName, $loadTime);
    foreach $table (@topPerfTables) { &runQuery("DELETE FROM $table"); }
    for  $tId ( 1 .. $nFileTypes ) {
        &runTopTypeQueriesPast($period, $theLimit, $tId, $siteName);
        foreach $table (@topPerfTables) { &runQuery("DELETE FROM $table"); }
    }
    &runTopFilesQueriesPast($period, $theLimit, $siteName);
    foreach $table (@topPerfTables) { &runQuery("DELETE FROM $table"); }
}
sub prepareStats4OneSite() {
    my ($siteName, $loadTime) = @_;

    my ($min, $hour, $wday) = &runQueryWithRet("SELECT MINUTE('$loadTime'),
                                                         HOUR('$loadTime'),
                                                      WEEKDAY('$loadTime') ");
    print "--> $siteName <--\n";

    # every min at HH:MM:00
    &runQuery("DELETE FROM ${siteName}_closedSessions_LastHour  
                     WHERE disconnectT < DATE_SUB('$loadTime', INTERVAL  1 HOUR)");
    &runQuery("DELETE FROM ${siteName}_closedFiles_LastHour     
                     WHERE      closeT < DATE_SUB('$loadTime', INTERVAL  1 HOUR)");
    &loadStatsLastHour($siteName, $loadTime, $min % 60);
    &loadTopPerfPast("Hour", $nTopPerfRows, $siteName, $loadTime);
    &forceClose($siteName, $loadTime, 1);

    if ( $min == 5 || $min == 20 || $min == 35 || $min == 50 ) {
        # with 5 minutes delay:
	# every 15 min at HH:00:00, HH:15:00, HH:00:00, HH:45:00
        &runQuery("DELETE FROM ${siteName}_closedSessions_LastDay  
                         WHERE disconnectT < DATE_SUB('$loadTime', INTERVAL  1 DAY)");
        &runQuery("DELETE FROM ${siteName}_closedFiles_LastDay     
                         WHERE      closeT < DATE_SUB('$loadTime', INTERVAL  1 DAY)");
	&loadStatsLastPeriod($siteName, $loadTime, "Day", "Hour");
        #                                          period cfPeriod
	&loadTopPerfPast("Day", $nTopPerfRows, $siteName, $loadTime);
    }

    if ( $min == 10) {
        # with 10 minutes delay:
	# every hour at HH:00:00
        &runQuery("DELETE FROM ${siteName}_closedSessions_LastWeek  
                         WHERE disconnectT < DATE_SUB('$loadTime', INTERVAL  7 DAY)");
        &runQuery("DELETE FROM ${siteName}_closedFiles_LastWeek     
                         WHERE      closeT < DATE_SUB('$loadTime', INTERVAL  7 DAY)");
	&loadStatsLastPeriod($siteName, $loadTime, "Week", "Day");
        #                                          period cfPeriod
	&loadTopPerfPast("Week", $nTopPerfRows, $siteName, $loadTime);
    }

    if ( $min == 15 ) {
        # with 15 minutes delay:
	if ( $hour == 0 || $hour == 6 || $hour == 12 || $hour == 18 ) {
	    # every 6 hours at 00:00:00, 06:00:00, 12:20:00, 18:00:00 GMT
            &runQuery("DELETE FROM ${siteName}_closedSessions_LastMonth  
                             WHERE disconnectT < DATE_SUB('$loadTime', INTERVAL 1 MONTH)");
            &runQuery("DELETE FROM ${siteName}_closedFiles_LastMonth     
                             WHERE      closeT < DATE_SUB('$loadTime', INTERVAL 1 MONTH)");
	    &loadStatsLastPeriod($siteName, $loadTime, "Month", "Day");
            #                                           period cfPeriod
	    &loadTopPerfPast("Month", $nTopPerfRows, $siteName, $loadTime);
            &fillStatsMissingBins($siteName,"Day",$loadTime);

	}
    }
    if ( $min == 50 ) {
	if ( $hour == 0 ) {
            # with 50 minutes delay:
	    # every 24 hours at 00:00:00 GMT
            &fillStatsMissingBins($siteName,"Week",$loadTime);
            &fillStatsMissingBins($siteName,"Month",$loadTime);
	}
        if ( $yearlyStats and $hour == 0 and $wday == 0 ) {
            # with 50 minutes delay:
            # every Sunday at 00:00:00 GMT
            &runQuery("DELETE FROM ${siteName}_closedSessions_LastYear  
                             WHERE disconnectT < DATE_SUB('$loadTime', INTERVAL 1 YEAR)");
            &runQuery("DELETE FROM ${siteName}_closedFiles_LastYear     
                             WHERE      closeT < DATE_SUB('$loadTime', INTERVAL 1 YEAR)");
	    &loadStatsLastPeriod($siteName, $loadTime, "Year", "Week");
            #                                          period cfPeriod
	    &loadTopPerfPast("Year", $nTopPerfRows, $siteName, $loadTime);
            
            if ( $allYearsStats ) { 
                &loadStatsAllYears($siteName, $loadTime);
            }
            &fillStatsMissingBins($siteName,"Year",$loadTime);
	}
    }

    # top Perf - "now"
    &loadTopPerfNow($nTopPerfRows, $siteName);

    # truncate temporary tables
    foreach $table (@topPerfTables) { &runQuery("DELETE FROM $table"); }
}
sub printNow() {
    my ($x) = @_;
    my $prev = $|;
    $| = 1;
    print $x;
    $| = $prev;
}

sub printUsage() {
    $opts = join('|', @_);
    die "Usage: $0 <configFile> $opts \n";
}     
sub readConfigFile() {
    my ($confFile, $caller, $print) = @_;
    unless ( open INFILE, "< $confFile" ) {
        print "Can't open file $confFile\n";
        exit;
    }

    $dbName = "";
    $mySQLUser = "";
    $webUser = "";
    $baseDir = "";
    $thisSite = "";
    $ctrPort = 9930;
    $backupIntDef = "1 DAY";
    $fileCloseWaitTime = "10 MINUNTE";
    $maxJobIdleTime = "15 MINUNTE";
    $maxSessionIdleTime = "12 HOUR";
    $maxConnectTime = "70 DAY";
    $closeFileInt = "15 MINUTE";
    $closeIdleSessionInt = "1 HOUR";
    $closeLongSessionInt = "1 DAY";
    $mysqlSocket = '/tmp/mysql.sock';
    $nTopPerfRows = 20;
    $yearlyStats = 0;
    $allYearsStats = 0;
    @flags = ('OFF', 'ON');
    @sites = ();


    while ( <INFILE> ) {
        chomp();
        my ($token, $v1, $v2, $v3, $v4) = split;
        if ( $token eq "dbName:" ) {
            $dbName = $v1;
        } elsif ( $token eq "MySQLUser:" ) {
            $mySQLUser = $v1;
        } elsif ( $token eq "webUser:" ) {
            $webUser = $v1;
        } elsif ( $token eq "MySQLSocket:" ) {
            $mysqlSocket = $v1;
        } elsif ( $token eq "baseDir:" ) {
            $baseDir = $v1;
        } elsif ( $token eq "ctrPort:" ) {
            $ctrPort = $v1;
        } elsif ( $token eq "thisSite:" ) {
            $thisSite = $v1;
        } elsif ( $token eq "site:" ) {
            push @sites, $v1;
            $timezones{$v1} = $v2;
            $firstDates{$v1} = "$v3 $v4";
        } elsif ( $token eq "backupIntDef:" ) {
            $backupIntDef = "$v1 $v2";
        } elsif ( $token eq "backupInt:" ) {
            $backupInts{$v1} = "$v2 $v3";
        } elsif ( $token eq "fileType:" ) {
            push @fileTypes, $v1;
            $maxRowsTypes{$v1} = $v2;
        } elsif ( $token eq "fileCloseWaitTime:" ) {
            $fileCloseWaitTime = "$v1 $v2";
        } elsif ( $token eq "maxJobIdleTime:" ) {
            $maxJobIdleTime = "$v1 $v2";
        } elsif ( $token eq "maxSessionIdleTime:" ) {
            $maxSessionIdleTime = "$v1 $v2";
        } elsif ( $token eq "maxConnectTime:" ) {
            $maxConnectTime = "$v1 $v2";
        } elsif ( $token eq "closeFileInt:" ) {
            $closeFileInt = "$v1 $v2";
        } elsif ( $token eq "closeIdleSessionInt:" ) {
            $closeIdleSessionInt = "$v1 $v2";
        } elsif ( $token eq "closeLongSessionInt:" ) {
            $closeLongSessionInt = "$v1 $v2";
        } elsif ( $token eq "nTopPerfRows:" ) {
            $nTopPerfRows = $v1;
        } elsif ( $token eq "yearlyStats:" ) {
            if ( lc($v1) eq "on" ) {$yearlyStats = 1;}
        } elsif ( $token eq "allYearsStats:" ) {
            if ( lc($v1) eq "on" ) {$allYearsStats = 1;}
        } else {
            print "Invalid entry: $_ \n";
            close INFILE;
            exit;
        }
    }
    close INFILE;
    # check missing tokens
    @missing = ();
    # $baseDir required for all callers except create
    if ( $caller ne "create" and ! $baseDir ) {
         push @missing, "baseDir";
    }

    if ( $caller eq "collector" ) {
         if ( ! $thisSite) {
            push @missing, "thisSite";    
         }
    } else { 
         if ( ! $dbName ) {push @missing, "dbName";}
         if ( ! $mySQLUser ) {push @missing, "mySQLUser";}
    }

    if ( @missing > 0 ) {
       print "Follwing tokens are missing from $confFile \n";
       foreach $token ( @missing ) {
           print "    $token \n";
       }
       exit
    }
    if ( $print ) {
        if ( $caller eq "collector" ) {
             print "  baseDir: $baseDir \n";
             print "  ctrPort: $ctrPort \n";
             print "  thisSite: $thisSite \n";
             return;
        }
        print "  dbName: $dbName  \n";
        print "  mySQLUser: $mySQLUser \n";
        print "  mysqlSocket: $mysqlSocket \n";
        print "  nTopPerfRows: $nTopPerfRows \n";
        if ( $caller eq "create" ) {
             print "backupIntDef: $backupIntDef \n";
             foreach $site ( @sites ) {
                 print "site: $site \n";
                 print "     timeZone: $timezones{$site}  \n";
                 print "     firstDate: $firstDates{$site} \n";
                 if ( $backupInts{$site} ) {
                     print "backupInt: $backupInts{$site} \n";
                 }
             }
             foreach $fileType ( @fileTypes ) {
                 print "fileType: $fileType $maxRowsTypes{$fileType} \n";
             }
         } else {
             print "  baseDir: $baseDir \n";
             print "  fileCloseWaitTime: $fileCloseWaitTime \n";
             print "  maxJobIdleTime: $maxJobIdleTime \n";
             print "  maxSessionIdleTime: $maxSessionIdleTime \n";
             print "  maxConnectTime: $maxConnectTime \n";
             print "  closeFileInt: $closeFileInt \n";
             print "  closeIdleSessionInt: $closeIdleSessionInt \n";
             print "  closeLongSessionInt: $closeLongSessionInt \n";
             print "  yearlyStats: $flags[$yearlyStats] \n";
             print "  allYearsStats: $flags[$allYearsStats] \n";
         }  
         if ( $caller eq "load" ) {
             foreach $site ( keys %backupInts ) {
                 print "  backupInts: $site $backupInts{$site} \n";
             }
         }
    }        
} 
    
sub returnHash() {
    ($_) = @_;
    my @primes = (101, 127, 157, 181, 199, 223, 239, 251, 271, 307);
    my $i = 1;
    tr/0-9a-zA-Z/0-90-90-90-90-90-90-1/;
    tr/0-9//cd;
    my $hashValue = 0;
    foreach $char ( split / */ ) {
	$i++;
	$hashValue += $i * $primes[$char];
    }
    return $hashValue;
}
sub roundoff() {
   my $a = shift;
   $d = 0;
   if ( $a < 10 ) {$d = $a < 1 ? 2 : 1;}
   return sprintf("%.${d}f", $a);
}

sub runQuery() {
    my ($sql) = @_;
#    print "$sql;\n";
    my $sth = $dbh->prepare($sql) 
        or die "Can't prepare statement $DBI::errstr\n";
    $sth->execute or die "Failed to exec \"$sql\", $DBI::errstr";
}
sub runQueryRetArray() {
    use vars qw(@theArray);
    my $sql = shift @_;
    @theArray = ();   
#    print "$sql;\n";
    my $sth = $dbh->prepare($sql) 
        or die "Can't prepare statement $DBI::errstr\n";
    $sth->execute or die "Failed to exec \"$sql\", $DBI::errstr";

    while ( @x = $sth->fetchrow_array ) {
	push @theArray, @x;
    };
    return @theArray;
}

sub runQueryRetNum() {
    my $sql = shift @_;
#    print "$sql;\n";
    my $num = $dbh-> do ($sql) or die "Failed to exec \"$sql\", $DBI::errstr";
    return $num;
}

sub runQueryWithRet() {
    my $sql = shift @_;
#    print "$sql;\n";
    my $sth = $dbh->prepare($sql) 
        or die "Can't prepare statement $DBI::errstr\n";
    $sth->execute or die "Failed to exec \"$sql\", $DBI::errstr";
    return $sth->fetchrow_array;
}
sub runTopFilesQueriesNow() {
    my ($theLimit, $siteName) = @_;

    &printNow("F\n");

    $destinationTable = "${siteName}_topPerfFilesNow";
    $pastTable        = "${siteName}_topPerfFilesPast";

    # now jobs
    &runQuery("INSERT INTO jj
          SELECT pathId, COUNT(jobId ) AS n
           FROM  ${siteName}_openedSessions os,
                 ${siteName}_openedFiles of
          WHERE  os.id = of.sessionId
       GROUP BY  pathId");


    ##### now find all names for top X for each sorting 
    &runQuery("REPLACE INTO xx SELECT theId FROM $pastTable");
    &runQuery("REPLACE INTO xx SELECT theId FROM jj ORDER BY n DESC LIMIT $theLimit");

    &runQuery("DELETE FROM $destinationTable");

    ## and finally insert the new data
    &runQuery("INSERT INTO $destinationTable
          SELECT  DISTINCT xx.theId,
                  IFNULL(jj.n, 0) AS jobs
            FROM  xx 
                  LEFT OUTER JOIN jj ON xx.theId = jj.theId");
}
sub runTopFilesQueriesPast() {
    my ($theKeyword, $theLimit, $siteName) = @_;

    my $oneChar = substr($theKeyword, 0, 1);
    &printNow("F \n");

    $destinationTable = "${siteName}_topPerfFilesPast";

    # past jobs
    &runQuery("INSERT INTO jj
            SELECT DISTINCT oc.pathId, COUNT(DISTINCT oc.jobId) AS n
              FROM (SELECT pathId, jobId
                      FROM ${siteName}_closedSessions_Last$theKeyword cs,
                           ${siteName}_closedFiles_Last$theKeyword cf
                     WHERE cs.id = cf.sessionId     
                 UNION ALL
                    SELECT pathId, jobId
                      FROM ${siteName}_openedSessions os,
                           ${siteName}_closedFiles_Last$theKeyword cf
                     WHERE os.id = cf.sessionId
                   )    AS oc
                   
          GROUP BY oc.pathId");

    # past volume 
    &runQuery("INSERT INTO vv
        SELECT pathId, 
               SUM(bytesR)/(1024*1024)
          FROM ${siteName}_closedFiles_Last$theKeyword
      GROUP BY pathId");

    ##### now find all names for top X for each sorting 
    &runQuery("REPLACE INTO xx SELECT theId FROM jj ORDER BY n DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM vv ORDER BY n DESC LIMIT $theLimit");

    ## delete old data
    &runQuery("DELETE FROM $destinationTable WHERE timePeriod LIKE '$theKeyword'");

    ## and finally insert the new data
        &runQuery("INSERT INTO $destinationTable
            SELECT xx.theId, 
                   IFNULL(jj.n, 0) AS jobs,
                   IFNULL(vv.n, 0) AS vol, 
                   '$theKeyword'
            FROM   xx 
                   LEFT OUTER JOIN jj ON xx.theId = jj.theId
                   LEFT OUTER JOIN vv ON xx.theId = vv.theId");
}

sub runTopTypeQueriesNow() {
    my ($theLimit, $tId, $siteName) = @_;

    &printNow("T$tId ");

    $destinationTable = "${siteName}_topPerfType_${tId}now";
    $pastTable        = "${siteName}_topPerfType_${tId}past";

    # now jobs
    &runQuery("INSERT INTO jj
        SELECT typeId_$tId,
               COUNT(DISTINCT jobId ) AS n
        FROM   ${siteName}_openedSessions os,
               ${siteName}_openedFiles of,
               fileInfo f
        WHERE  os.id = of.sessionId     AND
               of.pathId = f.id
      GROUP BY typeId_$tId");

    # now files
    &runQuery("REPLACE INTO ff 
        SELECT tmp.typeId_$tId,
               COUNT(tmp.pathId) AS n,
               SUM(tmp.size)/(1024*1024)  AS s
          FROM ( SELECT  DISTINCT typeId_$tId, pathId, size
                   FROM  ${siteName}_openedFiles of,
                         fileInfo f
                  WHERE  of.pathId = f.id
               )     AS  tmp
      GROUP BY tmp.typeId_$tId");

    # now users
    &runQuery("REPLACE INTO uu 
        SELECT typeId_$tId,
               COUNT(DISTINCT userId) AS n
          FROM ${siteName}_openedSessions os,
               ${siteName}_openedFiles of,
               fileInfo f
         WHERE os.id = of.sessionId
           AND of.pathId = f.id
      GROUP BY typeId_$tId");

    ##### now find all names for top X for each sorting 
    &runQuery("REPLACE INTO xx SELECT theId FROM $pastTable");
    &runQuery("REPLACE INTO xx SELECT theId FROM jj ORDER BY n DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM ff ORDER BY n DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM ff ORDER BY s DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM uu ORDER BY n DESC LIMIT $theLimit");

    &runQuery("DELETE FROM $destinationTable");

    ## and finally insert the new data
    &runQuery("INSERT INTO $destinationTable
        SELECT DISTINCT xx.theId,
               IFNULL(jj.n, 0) AS jobs,
               IFNULL(ff.n, 0) AS files, 
               IFNULL(ff.s, 0) AS fSize,
               IFNULL(uu.n, 0) AS users
        FROM   xx 
               LEFT OUTER JOIN jj ON xx.theId = jj.theId
               LEFT OUTER JOIN ff ON xx.theId = ff.theId
               LEFT OUTER JOIN uu ON xx.theId = uu.theId");
}
sub runTopTypeQueriesPast() {
    my ($period, $theLimit, $tId, $siteName) = @_;

    &printNow("T$tId ");

    $destinationTable = "${siteName}_topPerfType_${tId}past";

    # past jobs
    &runQuery("REPLACE INTO jj
        SELECT oc.theId,  
               COUNT(DISTINCT oc.jobId ) AS n
        FROM   (SELECT typeId_$tId AS theId, jobId
                  FROM ${siteName}_closedSessions_Last$period cs,
                       ${siteName}_closedFiles_Last$period cf,
                       fileInfo f
                 WHERE cs.id = cf.sessionId   AND
                       cf.pathId = f.id 
             UNION ALL
                SELECT typeId_$tId AS theId, jobId
                  FROM ${siteName}_openedSessions os,
                      ${siteName}_closedFiles_Last$period cf,
                       fileInfo f
                 WHERE os.id = cf.sessionId   AND
                       cf.pathId = f.id
               ) AS oc
     GROUP BY oc.theId");

    # past files
    &runQuery("INSERT INTO ff 
        SELECT tmp.typeId_$tId,
               COUNT(tmp.pathId),
               SUM(tmp.size)/(1024*1024)
          FROM ( SELECT DISTINCT typeId_$tId, pathId, size
                   FROM ${siteName}_closedFiles_Last$period cf,
                        fileInfo f
                  WHERE cf.pathId = f.id
               )     AS tmp
      GROUP BY tmp.typeId_$tId");


    # past users
    &runQuery("REPLACE INTO uu
       SELECT  typeId_$tId, 
               COUNT(DISTINCT userId) AS n
         FROM  ${siteName}_closedSessions_Last$period cs,
               ${siteName}_closedFiles_Last$period cf,
               fileInfo f
        WHERE  cs.id = cf.sessionId   AND
               cf.pathId = f.id
     GROUP BY  typeId_$tId");

    # past volume - through opened & closed sessions
    &runQuery("INSERT INTO vv
         SELECT typeId_$tId, 
                SUM(bytesR/(1024*1024))
           FROM ${siteName}_closedFiles_Last$period cf,
                fileInfo f
          WHERE cf.pathId = f.id
       GROUP BY typeId_$tId");

    ##### now find all names for top X for each sorting 
    &runQuery("REPLACE INTO xx SELECT theId FROM jj ORDER BY n DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM ff ORDER BY n DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM ff ORDER BY s DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM uu ORDER BY n DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM vv ORDER BY n DESC LIMIT $theLimit");

    ## delete old data
    &runQuery("DELETE FROM $destinationTable WHERE timePeriod LIKE '$period'");

    ## and finally insert the new data
    &runQuery("INSERT INTO $destinationTable
        SELECT xx.theId,
               IFNULL(jj.n, 0) AS jobs,
               IFNULL(ff.n, 0) AS files,
               IFNULL(ff.s, 0) AS fSize,
               IFNULL(uu.n, 0) AS users, 
               IFNULL(vv.n, 0) AS vol, 
               '$period'
        FROM   xx 
               LEFT OUTER JOIN jj ON xx.theId = jj.theId
               LEFT OUTER JOIN ff ON xx.theId = ff.theId
               LEFT OUTER JOIN uu ON xx.theId = uu.theId
               LEFT OUTER JOIN vv ON xx.theId = vv.theId");
}
sub runTopUsersQueriesNow() {
    my ($theLimit, $siteName) = @_;

    &printNow("Now: U ");

    $destinationTable = "${siteName}_topPerfUsersNow";
    $pastTable        = "${siteName}_topPerfUsersPast";

    # now jobs
    &runQuery("INSERT INTO jj
          SELECT  userId, COUNT(DISTINCT jobId ) AS n
            FROM  ${siteName}_openedSessions
        GROUP BY  userId");

    # now files
    &runQuery ("INSERT INTO ff 
          SELECT  tmp.userId, 
                  COUNT(tmp.pathId) AS n,
                  SUM(tmp.size)/(1024*1024) AS s
            FROM  (SELECT DISTINCT userId, pathId, size
                     FROM  ${siteName}_openedSessions os,
                           ${siteName}_openedFiles of,
                           fileInfo f
                    WHERE  os.id = of.sessionId     AND
                           of.pathId = f.id
                  )    AS  tmp
        GROUP BY  tmp.userId");

    ##### now find all names for top X for each sorting 
    &runQuery("REPLACE INTO xx SELECT theId FROM $pastTable");
    &runQuery("REPLACE INTO xx SELECT theId FROM jj ORDER BY n DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM ff ORDER BY n DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM ff ORDER BY s DESC LIMIT $theLimit");

    &runQuery("DELETE FROM $destinationTable");

    ## and finally insert the new data
    &runQuery("INSERT INTO $destinationTable
          SELECT  DISTINCT xx.theId,
                  IFNULL(jj.n, 0) AS jobs,
                  IFNULL(ff.n, 0) AS files, 
                  IFNULL(ff.s, 0) AS fSize
            FROM  xx 
                  LEFT OUTER JOIN jj ON xx.theId = jj.theId
                  LEFT OUTER JOIN ff ON xx.theId = ff.theId");
}
sub runTopUsersQueriesPast() {
    my ($theKeyword, $theLimit, $siteName, $loadTime) = @_;

    my $oneChar = substr($theKeyword, 0, 1);
    &printNow("$theKeyword: U ");

    $destinationTable = "${siteName}_topPerfUsersPast";

    # past jobs
    &runQuery("INSERT INTO jj
         SELECT userId, 
                COUNT(jobId) AS n
           FROM ${siteName}_jobs
          WHERE noOpenSessions = 0    AND
                endT > DATE_SUB('$loadTime', INTERVAL 1 $theKeyword)
       GROUP BY userId");

    # past files - through opened & closed sessions
    &runQuery("INSERT INTO ff           
        SELECT tmp.userId, 
               COUNT(tmp.pathId),
               SUM(tmp.size)/(1024*1024)
          FROM ( SELECT DISTINCT oc.userId, oc.pathId, oc.size
                   FROM ( SELECT userId, pathId, size 
                           FROM  ${siteName}_openedSessions os,
                                 ${siteName}_closedFiles_Last$theKeyword cf,
                                 fileInfo f
                          WHERE  os.id = cf.sessionId     AND
                                 cf.pathId = f.id 
                      UNION ALL
                         SELECT  userId, pathId, size 
                           FROM  ${siteName}_closedSessions_Last$theKeyword cs,
                                 ${siteName}_closedFiles_Last$theKeyword cf,
                                 fileInfo f
                          WHERE  cs.id = cf.sessionId    AND 
                                 cf.pathId = f.id 
                         )   AS  oc
                )   AS tmp
       GROUP BY tmp.userId");

    # past volume - through opened & closed sessions
    &runQuery("INSERT INTO vv
        SELECT oc.userId, 
               SUM(oc.bytesR)/(1024*1024)
          FROM ( SELECT  userId, bytesR
                   FROM  ${siteName}_openedSessions os,
                         ${siteName}_closedFiles_Last$theKeyword cf
                  WHERE  os.id = cf.sessionId
              UNION ALL
                 SELECT  userId, bytesR
                   FROM  ${siteName}_closedSessions_Last$theKeyword cs,
                         ${siteName}_closedFiles_Last$theKeyword cf
                  WHERE  cs.id = cf.sessionId
               )     AS  oc
      GROUP BY oc.userId");

    ##### now find all names for top X for each sorting 
    &runQuery("REPLACE INTO xx SELECT theId FROM jj ORDER BY n DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM ff ORDER BY n DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM ff ORDER BY s DESC LIMIT $theLimit");
    &runQuery("REPLACE INTO xx SELECT theId FROM vv ORDER BY n DESC LIMIT $theLimit");

    ## delete old data
    &runQuery("DELETE FROM $destinationTable WHERE timePeriod LIKE '$theKeyword'");

    ## and finally insert the new data
    &runQuery("INSERT INTO $destinationTable
               SELECT xx.theId, 
                      IFNULL(jj.n, 0) AS jobs, 
                      IFNULL(ff.n, 0) AS files, 
                      IFNULL(ff.s, 0) AS fSize, 
                      IFNULL(vv.n, 0) AS vol, 
                      '$theKeyword'
                 FROM xx 
                      LEFT OUTER JOIN jj ON xx.theId = jj.theId
                      LEFT OUTER JOIN ff ON xx.theId = ff.theId
                      LEFT OUTER JOIN vv ON xx.theId = vv.theId");
}

sub timeToSeqNo() {
    # return seq number for statsLast... tables
    my ($t2, $period) = @_;

    if ( $period eq 'Hour' ) {
        return (&runQueryWithRet("SELECT MINUTE('$t2') % 60"));
    } elsif ( $period eq 'Day' ) {
        return (&runQueryWithRet("SELECT HOUR('$t2')*4+FLOOR(MINUTE('$t2')/15)"));
    } elsif ( $period eq 'Week' ) {
        return (&runQueryWithRet("SELECT ((WEEKDAY('$t2')+1)%7)*24+HOUR('$t2')"));
    } elsif ( $period eq 'Month' ) {
        return (&runQueryWithRet("SELECT (DAY('$t2')-1)*4+FLOOR(HOUR('$t2')/6)"));
    } elsif ( $period eq 'Year' ) {
        return (&runQueryWithRet("SELECT DAYOFYEAR('$t2')"));
    }
}
sub timestamp() {
    my @localt = localtime(time());
    my $sec    = $localt[0];
    my $min    = $localt[1];
    my $hour   = $localt[2];
    my $day    = $localt[3];
    my $month  = $localt[4] + 1;
    my $year   = $localt[5] + 1900;

    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
                   $year, $month, $day, $hour, $min, $sec);
}

sub updateForClosedSessions() {
    my ($cs, $siteName, $loadTime, $loadLastTables) = @_;

    #insert contents of $cs table into closedSessions tables, delete them 
    # from openSession table and update the jobs table

    &runQuery("INSERT IGNORE INTO ${siteName}_closedSessions
                           SELECT *
                             FROM $cs ");

    &runQuery("DELETE FROM ${siteName}_openedSessions os
                     USING ${siteName}_openedSessions os, $cs cs
                     WHERE os.id = cs.id ");

    &runQuery("CREATE TEMPORARY TABLE IF NOT EXISTS ns ( jobId INT UNSIGNED NOT NULL PRIMARY KEY,
                                                           nos SMALLINT NOT NULL,
                                                           INDEX(nos)                            ) 
                                                           MAX_ROWS=65535                         ");

    &runQuery("INSERT INTO ns
                    SELECT jobId, count(jobId)
                      FROM $cs
                  GROUP BY jobId ");

    &runQuery("UPDATE ${siteName}_jobs j, ns
                  SET noOpenSessions = noOpenSessions - nos
                WHERE j.jobId = ns.jobId  ");

    if ( $loadLastTables ) {
        foreach $period ( @periods ) {
            &runQuery("INSERT IGNORE INTO ${siteName}_closedSessions_Last$period
                            SELECT *
                              FROM $cs
                             WHERE disconnectT > DATE_SUB('$loadTime', INTERVAL 1 $period) ");
        }
    } else {
        &runQuery("INSERT IGNORE INTO closedSessions
                               SELECT *
                                 FROM $cs ");
    }

    &runQuery("DROP TABLE IF EXISTS ns");
}
