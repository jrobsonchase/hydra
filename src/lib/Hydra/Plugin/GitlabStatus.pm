package Hydra::Plugin::GitlabStatus;

use strict;
use warnings;
use parent 'Hydra::Plugin';
use HTTP::Request;
use JSON::MaybeXS;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;
use List::Util qw(max);

# This plugin expects as inputs to a jobset the following:
#   - gitlab_status_repo => Name of the repository input pointing to that
#     status updates should be POST'ed, i.e. the jobset has a git input
#     "nixexprs": "https://gitlab.example.com/project/nixexprs", in which
#     case "gitlab_status_repo" would be "nixexprs".
#   - (optional) gitlab_project_id => ID of the project in Gitlab, i.e. in the above
#     case the ID in gitlab of "nixexprs"

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{gitlab_authorization};
}

sub toGitlabState {
    my ($status, $buildStatus) = @_;
    if ($status == 0) {
        return "pending";
    } elsif ($status == 1) {
        return "running";
    } elsif ($buildStatus == 0) {
        return "success";
    } elsif ($buildStatus == 3 || $buildStatus == 4 || $buildStatus == 8 || $buildStatus == 10 || $buildStatus == 11) {
        return "canceled";
    } else {
        return "failed";
    }
}

sub common {
    my ($self, $topbuild, $dependents, $status, $cachedEval) = @_;
    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

    # Find matching configs
    foreach my $build ($topbuild, @{$dependents}) {
        my $jobName = showJobName $build;
        my $evals = $topbuild->jobsetevals;
        my $ua = LWP::UserAgent->new();

        # Don't send out "pending/running" status updates if the build is already finished
        next if $status < 2 && $build->finished == 1;

        my $state = toGitlabState($status, $build->buildstatus);
        my $body = encode_json(
            {
                state => $state,
                target_url => "$baseurl/build/" . $build->id,
                description => "Hydra build #" . $build->id . " of $jobName",
                name => "Hydra " . $build->get_column('job'),
            });

        my $sendStatus = sub {
            my ($domain, $owner, $repo, $projectId, $rev) = @_;
            my $accessToken;
            if (defined $projectId) {
                $accessToken = $self->{config}->{gitlab_authorization}->{$projectId};
            } else {
                $accessToken = $self->{config}->{gitlab_authorization}->{$owner};
                $projectId = "$owner/$repo" =~ s/\//%2F/rg;
            }
            my $url = "https://$domain/api/v4/projects/$projectId/statuses/$rev";
            print STDERR "GitlabStatus POSTing $state to $url\n";
            my $req = HTTP::Request->new('POST', $url);
            $req->header('Content-Type' => 'application/json');
            $req->header('Private-Token' => $accessToken);
            $req->content($body);
            my $res = $ua->request($req);
            print STDERR $res->status_line, ": ", $res->decoded_content, "\n" unless $res->is_success;
        };

        while (my $eval = $evals->next) {
            if (defined($cachedEval) && $cachedEval->id != $eval->id) {
                next;
            }
            if (defined $eval->flake) {
                my $fl = $eval->flake;
                print STDERR "Flake is $fl\n";
                if ($eval->flake =~ m!gitlab:([^/]+)/([^/]+)/([[:xdigit:]]{40})$!) {
                    my $owner = $1;
                    my $repo = $2;
                    my $rev = $3;
                    $sendStatus->("gitlab.com", $owner, $repo, undef, $rev);
                } elsif ($eval->flake =~ m!git\+ssh://git\@([^/]+)/([^/]+)/([^?]+)\?.*rev=([[:xdigit:]]{40})$!) {
                    my $domain = $1;
                    my $owner = $2;
                    my $repo = $3;
                    my $rev = $4;
                    $sendStatus->($domain, $owner, $repo, undef, $rev);
                } else {
                    print STDERR "Can't parse flake, skipping Gitlab status update\n";
                }
            } else {
                my $projectId;
                my $projectIdInput = $eval->jobsetevalinputs->find({ name => "gitlab_project_id" });
                if (defined $projectIdInput) {
                    $projectId = $projectIdInput->value;
                }
                my $gitlabstatusInput = $eval->jobsetevalinputs->find({ name => "gitlab_status_repo" });
                next unless defined $gitlabstatusInput && defined $gitlabstatusInput->value;
                my $i = $eval->jobsetevalinputs->find({ name => $gitlabstatusInput->value, altnr => 0 });
                next unless defined $i;
                my $rev = $i->revision;
                my $domain = URI->new($i->uri)->host;
                my $uri = $i->uri;
                $uri =~ m![:/]([^/]+)/(.+?)(?:.git)?$!;
                $sendStatus->($domain, $1, $2, $projectId, $rev);
            }
        }
    }
}

sub buildQueued {
    common(@_, [], 0);
}

sub buildStarted {
    common(@_, [], 1);
}

sub buildFinished {
    common(@_, 2);
}

sub cachedBuildQueued {
    my ($self, $evaluation, $build) = @_;
    common($self, $build, [], 0, $evaluation);
}

sub cachedBuildFinished {
    my ($self, $evaluation, $build) = @_;
    common($self, $build, [], 2, $evaluation);
}

1;
