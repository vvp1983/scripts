#!/usr/bin/perl
use 5.010;
use strict;
use warnings;
use Scalar::Util qw(
  blessed
 );
use Try::Tiny;

use Kafka qw(
        $DEFAULT_MAX_BYTES
        $DEFAULT_MAX_NUMBER_OF_OFFSETS
        $RECEIVE_EARLIEST_OFFSETS
        $RECEIVE_LATEST_OFFSET
    );
use Kafka::Connection;
use Kafka::Consumer;

use Scalar::Util;
use JSON::Parse 'parse_json_safe';
use utf8;


use UUID::Generator::PurePerl;
use MIME::Base64;

my @metrics;
my $topic_name='jsondocuments';
my $ug = UUID::Generator::PurePerl->new();

my $file_offset="/opt/next_offset.log";
my $next_offset="";
my $last_offset="";



sub ReadLastOffset
{
    open (my $fh,"$file_offset") or die "Can not open file for read $file_offset";
    while (my $offset = <$fh>)
    {
        chomp $offset;
        $last_offset="$offset";
    }
    close ($fh);
}

    my ( $connection, $consumer );

GetKafkaMessages();

# Получение новых сообщений из Kafka

sub GetKafkaMessages
{
    ReadLastOffset();
    try {

        #-- Connection
        $connection = Kafka::Connection->new( host => '172.19.0.3' );
        #-- Consumer
        $consumer = Kafka::Consumer->new( Connection  => $connection );

        # Get a list of valid offsets up max_number before the given time

         my $offsets = $consumer->offsets(
            'jsondocuments',                      # topic
            0,                              # partition
            $RECEIVE_LATEST_OFFSET,      # time
            $DEFAULT_MAX_NUMBER_OF_OFFSETS  # max_number
        );
        if ( @$offsets ) {
            do {  say "Received offset: $_"; } foreach @$offsets;
    #        $next_offset=@{$offsets}[0]; say $next_offset;
        } else {
            warn "Error: Offsets are not received\n";
        }
        if($last_offset eq @{$offsets}[0]){ say "We get all messages"; exit;}
        say $last_offset;
        # Consuming messages
        my $messages = $consumer->fetch(
            'jsondocuments',                      # topic
            0,                              # partition
            $last_offset,         # offset
            10485760           # Maximum size of MESSAGE(s) to receive
        );


        if ( $messages ) {
            foreach my $message ( @$messages ) {
                if ( $message->valid ) {
                    $next_offset=$message->next_offset;
#                    say 'payload    :',$message->payload;
                    parsejson($message->payload);
                    ImportToMyMetricsKX();
                    NextOffsetSet();
                    @metrics=();
                } else {
                    say 'error      : ', $message->error;
                }
            }
        }

    } catch {
        my $error = $_;
        if ( blessed( $error ) && $error->isa( 'Kafka::Exception' ) ) {
            warn 'Error: (', $error->code, ') ',  $error->message, "\n";
            exit;
        } else {
            die $error;
        }
    };

    # Closes the consumer and cleans up
    undef $consumer;
    $connection->close;
    undef $connection;
}



sub NextOffsetSet
{
    open (my $fh, ">/opt/next_offset.log") or die "Cannot open file";
    printf $fh "%d", $next_offset;
    close ($fh);
}

#Импортирование полученных данных в ClickHouse

sub ImportToMyMetricsKX
{
    my $ch="jira.domain.local:8123";

    open PIPE, "| curl -s  --data-binary \@- http://default:1111uoijafkjs\@$ch/?" or die "can't fork: $!";

    my $head='INSERT INTO my_metrics(`template`,`user`,`org`,`element_id`,`type`,`document_id`,`value`,`datetime`,`date`,DueTime) VALUES';
    print PIPE "$head\n";

    foreach  my $s (@metrics)
    {
        print PIPE "$s,";
    }

    close PIPE;
}

#Парсер полученных данных, формирование строки для вставки в КХ
sub parsejson
{
    my $req=shift;
#    say $req;

     my $p = parse_json_safe($req);
    say $p;
    if( $@ ) {return;};
    if(ref($p) eq 'HASH')
    {
     my $complete=$p->{'CompleteTime'};
     my $template=$p->{'template_id'};
     my $initiator= $p->{'initiator'};
     my $executor= $p->{'executor'};
     my $duetime=$p->{'DueTime'};
     my $site_id=$p->{'site_id'};

    if ( !$template || !$initiator || !$executor || !$complete || !$site_id ) { return ; };

    (my $datetime)= $complete =~ /^(\d{4}\-\d{2}\-\d{2}T\d{2}\:\d{2}\:\d{2})/;
    ($duetime)= $duetime =~ /^(\d{4}\-\d{2}\-\d{2}T\d{2}\:\d{2}\:\d{2})/;

     my $document_id=$ug->generate_v1();
     $document_id=$document_id->as_string();

     foreach my $k (keys %{$p})
    {
        if(ref($p->{$k}) eq 'ARRAY')
             {
                my $size=@{$p->{$k}};
                for my $i (0..$size-1)
                {
                 my $type=${$p->{$k}}[$i]->{'type'};
                 if($type eq 'question' || $type eq 'checkbox' || $type eq 'slider' || $type eq 'float')
                {
                 my $value=${$p->{$k}}[$i]->{'value'};
                 my $element_id=${$p->{$k}}[$i]->{'id'};
                 if ( $type && $value && $element_id) {
                    #'INSERT INTO my_metrics(`template`,`user`,`org`,`element_id`,`type`,`value`,`document_id`,`datetime`,`date`,DueTime) VALUES';
                    my $str='(\''.$template.'\',\''.$executor.'\',\''.$site_id.'\',\''.$element_id.'\',\''.$type.'\',\''.$document_id.'\',\''.$value.'\',\''.$datetime.'\',toDate(\''.$datetime.'\'),\''.$duetime.'\')';
                    push @metrics,$str;
                    print $str."\n";
                    }
                }
                }
            }

        }
   }

}
