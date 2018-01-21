package JIRA::REST::Class::Issue;
use parent qw( JIRA::REST::Class::Abstract );
use strict;
use warnings;
use 5.010;

our $VERSION = '0.13';
our $SOURCE = 'CPAN';
$SOURCE = 'GitHub';  # COMMENT
# the line above will be commented out by Dist::Zilla

# ABSTRACT: A helper class for L<JIRA::REST::Class|JIRA::REST::Class> that represents an
# individual JIRA issue as an object.

use Carp;
use Readonly 2.04;
use Scalar::Util qw( weaken );

# creating a bunch of read-only accessors

# contextual returns lists or arrayrefs, depending on context
Readonly my @CONTEXTUAL => qw( components versions );

__PACKAGE__->mk_contextual_ro_accessors( @CONTEXTUAL );

# fields that will be turned into JIRA::REST::Class::User objects
Readonly my @USERS => qw( assignee creator reporter );

# fields that will be turned into DateTime objects
Readonly my @DATES => qw( created duedate lastViewed resolutiondate updated );

# other fields we're objectifying and storing at the top level of the hash
Readonly my @TOP_LEVEL => qw( project issuetype status url );

__PACKAGE__->mk_ro_accessors( @TOP_LEVEL, @USERS, @DATES );

# fields that are under $self->{data}
Readonly my @DATA => qw( expand fields id key self );
__PACKAGE__->mk_data_ro_accessors( @DATA );

# fields that are under $self->{data}->{fields}
Readonly my @FIELDS => qw( aggregateprogress aggregatetimeestimate
                           aggregatetimeoriginalestimate aggregatetimespent
                           description environment fixVersions issuelinks
                           labels priority progress resolution summary
                           timeestimate timeoriginalestimate timespent
                           votes watches workratio );

__PACKAGE__->mk_field_ro_accessors( @FIELDS );

=head1 DESCRIPTION

This object represents a JIRA issue as an object.  It is overloaded so it
returns the C<key> of the issue when stringified, and the C<id> of the issue
when it is used in a numeric context.  If two of these objects are compared
I<as strings>, the C<key> of the issues will be used for the comparison,
while numeric comparison will compare the C<id>s of the issues.

=cut

#<<<
use overload
    '""'  => sub { shift->key },
    '0+'  => sub { shift->id  },
    '<=>' => sub {
        my( $A, $B ) = @_;
        my $AA = ref $A ? $A->id : $A;
        my $BB = ref $B ? $B->id : $B;
        $AA <=> $BB
    },
    'cmp' => sub {
        my( $A, $B ) = @_;
        my $AA = ref $A ? $A->key : $A;
        my $BB = ref $B ? $B->key : $B;
        $AA cmp $BB
    };
#>>>

sub init {
    my $self = shift;
    $self->SUPER::init( @_ );

    my $jira = $self->jira;
    $self->{url} = $jira->strip_protocol_and_host( $self->self );

    # make user objects
    foreach my $field ( @USERS ) {
        $self->populate_scalar_field( $field, 'user', $field );
    }

    # make date objects
    foreach my $field ( @DATES ) {
        $self->{$field} = $self->make_date( $self->fields->{$field} );
    }

    $self->populate_list_field( 'components', 'projectcomp', 'components' );
    $self->populate_list_field( 'versions',   'projectvers', 'versions' );
    $self->populate_scalar_field( 'project',   'project',   'project' );
    $self->populate_scalar_field( 'issuetype', 'issuetype', 'issuetype' );
    $self->populate_scalar_field( 'status',    'status',    'status' );
    $self->populate_scalar_field(  #
        'timetracking', 'timetracking', 'timetracking',
    );

    # if no_is_issue_type was passed to the constructor with a true value,
    # don't define any is_{issue_type} methods.
    unless ( $jira->no_is_issue_type || defined &is_bug ) {

        # if we haven't defined booleans to determine whether or not this
        # issue is a particular type, define those methods now
        foreach my $type ( $jira->issue_types ) {
            ( my $subname = lc 'is_' . $type->name ) =~ s/\s+|\-/_/xmsg;
            $self->make_subroutine(
                $subname,
                sub {
                    shift->fields->{issuetype}->{id} == $type->id;
                }
            );
        }
    }
    return;
}

sub component_count { return scalar @{ shift->{components} } }

#
# rather than just use the minimal information in the issue's
# parent hash, fetch the parent issue fully when someone first
# uses the parent_accessor
#

sub has_parent { return exists shift->fields->{parent} }

__PACKAGE__->mk_lazy_ro_accessor(
    'parent',
    sub {
        my $self = shift;
        return unless $self->has_parent;  # some issues have no parent

        my $parent = $self->fields->{parent}->{self};
        my $url    = $self->jira->strip_protocol_and_host( $parent );
        return $self->make_object(
            'issue',
            {
                data => $self->jira->get( $url )
            }
        );
    }
);

__PACKAGE__->mk_lazy_ro_accessor(
    'changelog',
    sub {
        my $self = shift;
        return $self->make_object( 'changelog' );
    }
);

__PACKAGE__->mk_lazy_ro_accessor(
    'comments',
    sub {
        my $self = shift;
        my $data = $self->get( '/comment' );
        return $self->{comments} = [  #
            map {                     #
                $self->make_object( 'comment', { data => $_ } );
            } @{ $data->{comments} }
        ];
    }
);

__PACKAGE__->mk_lazy_ro_accessor(
    'worklog',
    sub {
        my $self = shift;
        return $self->make_object( 'worklog' );
    }
);

__PACKAGE__->mk_lazy_ro_accessor(
    'transitions',
    sub {
        my $self = shift;
        return $self->make_object( 'transitions' );
    }
);

__PACKAGE__->mk_lazy_ro_accessor(
    'timetracking',
    sub {
        my $self = shift;
        return $self->make_object( 'timetracking' );
    }
);

=internal_method B<make_object>

A pass-through method that calls
L<JIRA::REST::Class::Factory::make_object()|JIRA::REST::Class::Factory/make_object>,
but adds a weakened link to this issue in the object as well.

=cut

sub make_object {
    my $self = shift;
    my $type = shift;
    my $args = shift || {};

    # if we weren't passed an issue, link to ourselves
    unless ( exists $args->{issue} ) {
        $args->{issue} = $self;
    }

    my $class = $self->factory->get_factory_class( $type );
    my $obj   = $class->new( $args );

    if ( exists $obj->{issue} ) {
        weaken $obj->{issue};  # make the link to ourselves weak
    }

    $obj->init( $self->factory );  # NOW we call init

    return $obj;
}

###########################################################################

=method B<add_attachments>

Accepts a list of filenames to be added to the issue as attachments.

=cut

sub add_attachments {
    my ( $self, @args ) = @_;

    foreach my $file ( @args ) {
        croak "unable to find attachment $file"
            unless -f $file;

        $self->JIRA_REST->attach_files( $self->key, $file );
    }
    return;
}

=method B<add_attachment>

Accepts a single filename to be added to the issue as an attachment.

=cut

sub add_attachment {
    my $self = shift;
    my $file = shift;

    croak "unable to find attachment $file"
        unless -f $file;

    return $self->JIRA_REST->attach_files( $self->key, $file );
}

=method B<add_data_attachment>

Accepts a fake filename and a scalar representing the contents of a file and
adds it to the issue as an attachment.

=cut

sub add_data_attachment {
    my $self = shift;
    my $name = shift;
    my $data = shift;
    my $url  = q{/} . join q{/}, 'issue', $self->key, 'attachments';

    return $self->jira->data_upload(
        {
            url  => $url,
            name => $name,
            data => $data
        }
    );
}

=method B<add_comment>

Adds whatever is passed in as a comment on the issue.

=cut

sub add_comment {
    my $self = shift;
    my $text = shift;
    return $self->post( '/comment', { body => $text } );
}

=method B<add_label>

Adds whatever is passed in as a label for the issue.

=cut

sub add_label {
    my $self  = shift;
    my $label = shift;
    return $self->update( labels => [ { add => $label } ] );
}

=method B<remove_label>

Removes whatever is passed in from the labels for the issue.

=cut

sub remove_label {
    my $self  = shift;
    my $label = shift;
    return $self->update( labels => [ { remove => $label } ] );
}

=method B<has_label>

Returns true if the issue has the specified label.

=cut

sub has_label {
    my $self  = shift;
    my $label = shift;
    foreach my $has ( $self->labels ) {
        return 1 if $label eq $has;
    }
    return 0;
}

=method B<add_component>

Adds whatever is passed in as a component for the issue.

=cut

sub add_component {
    my $self = shift;
    my $comp = shift;
    return $self->update( components => [ { add => { name => $comp } } ] );
}

=method B<remove_component>

Removes whatever is passed in from the components for the issue.

=cut

sub remove_component {
    my $self = shift;
    my $comp = shift;
    return $self->update( components => [ { remove => { name => $comp } } ] );
}

=method B<set_assignee>

Sets the assignee for the issue to be the user passed in.  Can either be a
string representing the name or a
L<JIRA::REST::Class::User|JIRA::REST::Class::User> object.

=cut

sub set_assignee {
    my ( $self, @args ) = @_;
    my $name = $self->name_for_user( @args );
    return $self->put_field( assignee => { name => $name } );
}

=method B<set_reporter>

Sets the reporter for the issue to be the user passed in.  Can either be a
string representing the name or a
L<JIRA::REST::Class::User|JIRA::REST::Class::User> object.

=cut

sub set_reporter {
    my $self = shift;
    my $name = $self->name_for_user( shift );
    return $self->put_field( reporter => { name => $name } );
}

=method B<add_issue_link>

Adds a link from this issue to another one.  Accepts the link type (either a
string representing the name or a
L<JIRA::REST::Class::Issue::LinkType|JIRA::REST::Class::Issue::LinkType>),
the issue to be linked to, and (optionally) the direction of the link
(inward/outward).  If the direction cannot be determined from the name of
the link type, the default direction is 'inward';

=cut

sub add_issue_link {
    my ( $self, $type, $key, $dir ) = @_;
    $key = $self->key_for_issue( $key );
    ( $type, $dir ) = $self->find_link_name_and_direction( $type, $dir );

    my $links = [
        {
            add => {
                type           => { name => $type },
                $dir . 'Issue' => { key  => $key },
            },
        }
    ];
    return $self->update( issuelinks => $links );
}

=method B<add_subtask>

Adds a subtask to the current issue.  Accepts a hashref with named parameters
C<summary> and C<description>.  If the parameter C<issuetype> is specified,
then a subtask of the specified type is created.  If no issuetype is
specified, then the project is queried for valid subtask types, and, if there
is only one, that type is used.  If the project has more than one valid
subtask type, an issuetype B<MUST> be specified.

The remaining named parameters are passed to the create issue call as fields.

=cut

sub add_subtask {
    my ( $self, @args ) = @_;

    my $fields;
    if ( @args == 1 && ref $args[0] && ref $args[0] eq 'HASH' ) {
        $fields = $args[0];
    }
    else { ## backward compatibility
        $fields = $args[2] // {};

        $fields->{summary}     //= shift @args;
        $fields->{description} //= shift @args;
    }

    my $project   = $self->_get_subtask_project( $fields );
    my $parent    = $self->_get_subtask_parent( $fields );
    my $issuetype = $self->_get_subtask_issue_type( $project, $fields );

    my $data = {
        fields => {
            project   => { key => $project->key },
            parent    => { key => $parent->key },
            issuetype => { id  => $issuetype->id },
        }
    };

    if ( $fields ) {
        foreach my $field ( keys %$fields ) {
            next
                if $field eq 'project'
                || $field eq 'parent'
                || $field eq 'issuetype';
            $data->{fields}->{$field} = $fields->{$field};
        }
    }

    my $result = $self->jira->post( '/issue', $data );
    my $url = '/issue/' . $result->{id};

    return $self->factory->make_object(
        'issue',
        {
            data => $self->jira->get( $url )
        }
    );
}

sub _get_subtask_project {
    my ( $self, $fields ) = @_;

    return $self->project
        unless exists $fields->{project} && defined $fields->{project};

    my $proj = $fields->{project};

    if ( $self->obj_isa( $proj, 'project' ) ) {

        # we were passed an issue type object
        return $proj;
    }

    my ( $project ) = grep { ##
        $_->id eq $proj || $_->name eq $proj
    } $self->jira->projects;

    return $project if $project;

    local $Carp::CarpLevel = $Carp::CarpLevel + 1;
    confess "add_subtask() called with unknown project '$proj'";
}

sub _get_subtask_parent {
    my ( $self, $fields ) = @_;

    # if we're not passed a parent parameter, we're the parent
    return $self
        unless exists $fields->{parent} && defined $fields->{parent};

    my $issue = $fields->{parent};
    if ( $self->obj_isa( $issue, 'issue' ) ) {

        # we were passed an issue type object
        return $issue;
    }

    my ( $parent ) = $self->jira->issues( $issue );

    return $parent if $parent;

    local $Carp::CarpLevel = $Carp::CarpLevel + 2;
    confess "add_subtask() called with unknown parent '$issue'";
}

sub _get_subtask_issue_type {
    my ( $self, $project, $fields ) = @_;

    # let's set this once in case we need to throw an exception
    local $Carp::CarpLevel = $Carp::CarpLevel + 2;

    if ( exists $fields->{issuetype} && defined $fields->{issuetype} ) {
        my $type = $fields->{issuetype};

        if ( $self->obj_isa( $type, 'issuetype' ) ) {

            # we were passed an issue type object
            return $type if $type->subtask;

            confess
                "add_subtask() called with a non-subtask issue type: '$type'";
        }

        my ( $issuetype ) = grep { ##
            $_->id eq $type || $_->name eq $type
        } $project->issueTypes;

        return $issuetype if $issuetype && $issuetype->subtask;

        if ( !defined $issuetype ) {
            confess 'add_subtask() called with a value that does not '
                . "correspond to a known issue type: '$type'";
        }

        confess
            "add_subtask() called with a non-subtask issue type: '$issuetype'";
    }

    # we didn't get passed an issue type, so let's find one

    my @subtasks = $self->project->subtaskIssueTypes;

    if ( @subtasks == 1 ) {
        return $subtasks[0];
    }

    my $count = scalar @subtasks;
    my $list = join q{, } => @subtasks;

    confess 'add_subtask() called without specifying a subtask type; '
        . "there are $count subtask types: $list";
}

###########################################################################

=method B<update>

Puts an update to JIRA.  Accepts a hash of fields => values to be put.

=cut

sub update {
    my $self = shift;
    my $hash = {};
    while ( @_ ) {
        my $field = shift;
        my $value = shift;
        $hash->{$field} = $value;
    }
    return $self->put(
        {
            update => $hash,
        }
    );
}

=method B<put_field>

Puts a value to a field.  Accepts the field name and the value as parameters.

=cut

sub put_field {
    my $self  = shift;
    my $field = shift;
    my $value = shift;
    return $self->put(
        {
            fields => { $field => $value },
        }
    );
}

=method B<reload>

Reload the issue from the JIRA server.

=cut

sub reload {
    my $self = shift;
    $self->{data} = $self->get;
    $self->init( $self->factory );
    return;
}

###########################################################################

=internal_method B<get>

Wrapper around C<JIRA::REST::Class>' L<get|JIRA::REST::Class/get> method that
defaults to this issue's URL. Allows for extra parameters to be specified.

=cut

sub get {
    my ( $self, $extra, @args ) = @_;
    $extra //= q{};
    return $self->jira->get( $self->url . $extra, @args );
}

=internal_method B<post>

Wrapper around C<JIRA::REST::Class>' L<post|JIRA::REST::Class/post> method
that defaults to this issue's URL. Allows for extra parameters to be
specified.

=cut

sub post {
    my ( $self, $extra, @args ) = @_;
    $extra //= q{};
    return $self->jira->post( $self->url . $extra, @args );
}

=internal_method B<put>

Wrapper around C<JIRA::REST::Class>' L<put|JIRA::REST::Class/put> method that
defaults to this issue's URL. Allows for extra parameters to be specified.

=cut

sub put {
    my ( $self, @args ) = @_;
    return $self->jira->put( $self->url, @args );
}

=internal_method B<delete>

Wrapper around C<JIRA::REST::Class>' L<delete|JIRA::REST::Class/delete> method
that defaults to this issue's URL. Allows for extra parameters to be
specified.

=cut

sub delete { ## no critic (ProhibitBuiltinHomonyms)
    my ( $self, $extra, @args ) = @_;
    $extra //= q{};
    return $self->jira->delete( $self->url . $extra, @args );
}

=method B<sprints>

Generates a list of L<JIRA::REST::Class::Sprint|JIRA::REST::Class::Sprint>
objects from the fields for an issue.  Uses the field_name() accessor on the
L<JIRA::REST::Class::Project|JIRA::REST::Class::Project/"field_name
FIELD_KEY"> object to determine the name of the custom sprint
field. Currently, this only really works if you're using L<Atlassian
GreenHopper|https://www.atlassian.com/software/jira/agile>.

=cut

__PACKAGE__->mk_lazy_ro_accessor(
    'sprints',
    sub {
        my $self = shift;

        # in my configuration, 'Sprint' is a custom field
        my $sprint_field = $self->project->field_name( 'Sprint' );

        my @sprints;
        foreach my $sprint ( @{ $self->fields->{$sprint_field} } ) {
            push @sprints, $self->make_object( 'sprint', { data => $sprint } );
        }
        return \@sprints;
    }
);

#<<<

=method B<children>

Returns a list of issue objects that are children of the issue. Currently
requires the L<ScriptRunner
plugin|https://marketplace.atlassian.com/plugins/com.onresolve.jira.groovy.groovyrunner/cloud/overview>.

=cut

#>>>

sub children {
    my $self     = shift;
    my $key      = $self->key;
    my $children = $self->jira->query(
        {
            jql => qq{issueFunction in subtasksOf("key = $key")}
        }
    );

    return unless $children->issue_count;
    return $children->issues;
}

###########################################################################

=method B<start_progress>

Moves the status of the issue to 'In Progress', regardless of what the current
status is.

=cut

sub start_progress {
    my $self     = shift;
    my $callback = shift;
    $callback //= sub { };

    return $self->transitions->transition_walk(
        'In Progress',
        {
            'Open'     => 'In Progress',
            'Reopened' => 'In Progress',
            'In QA'    => 'In Progress',
            'Blocked'  => 'In Progress',
            'Resolved' => 'Reopened',
            'Verified' => 'Reopened',
            'Closed'   => 'Reopened',
        },
        $callback
    );
}

=method B<start_qa>

Moves the status of the issue to 'In QA', regardless of what the current
status is.

=cut

sub start_qa {
    my $self     = shift;
    my $callback = shift;
    $callback //= sub { };

    return $self->transitions->transition_walk(
        'In QA',
        {
            'Open'        => 'In Progress',
            'In Progress' => 'Resolved',
            'Reopened'    => 'Resolved',
            'Resolved'    => 'In QA',
            'Blocked'     => 'In QA',
            'Verified'    => 'Reopened',
            'Closed'      => 'Reopened',
        },
        $callback
    );
}

=method B<resolve>

Moves the status of the issue to 'Resolved', regardless of what the current
status is.

=cut

sub resolve {
    my $self     = shift;
    my $callback = shift;
    $callback //= sub { };

    return $self->transitions->transition_walk(
        'Resolved',
        {
            'Open'        => 'In Progress',
            'In Progress' => 'Resolved',
            'Reopened'    => 'Resolved',
            'Blocked'     => 'In Progress',
            'In QA'       => 'In Progress',
            'Verified'    => 'Reopened',
            'Closed'      => 'Reopened',
        },
        $callback
    );
}

=method B<open>

Moves the status of the issue to 'Open', regardless of what the current status is.

=cut

sub open { ## no critic (ProhibitBuiltinHomonyms)
    my $self     = shift;
    my $callback = shift;
    $callback //= sub { };

    return $self->transitions->transition_walk(
        'Open',
        {
            'In Progress' => 'Open',
            'Reopened'    => 'In Progress',
            'Blocked'     => 'In Progress',
            'In QA'       => 'In Progress',
            'Resolved'    => 'Reopened',
            'Verified'    => 'Reopened',
            'Closed'      => 'Reopened',
        },
        $callback
    );
}

=method B<close>

Moves the status of the issue to 'Closed', regardless of what the current status is.

=cut

sub close { ## no critic (ProhibitBuiltinHomonyms ProhibitAmbiguousNames)
    my $self     = shift;
    my $callback = shift;
    $callback //= sub { };

    return $self->transitions->transition_walk(
        'Closed',
        {
            'Open'        => 'In Progress',
            'In Progress' => 'Resolved',
            'Reopened'    => 'Resolved',
            'Blocked'     => 'In Progress',
            'In QA'       => 'Verified',
            'Resolved'    => 'Closed',
            'Verified'    => 'Closed',
        },
        $callback
    );
}

1;

=accessor B<expand>

A comma-separated list of fields in the issue that weren't expanded in the
initial REST call.

=accessor B<fields>

Returns a reference to the fields hash for the issue.

=accessor B<aggregateprogress>

Returns the aggregate progress for the issue as a hash reference.

TODO: Turn this into an object.

=accessor B<aggregatetimeestimate>

Returns the aggregate time estimate for the issue.

TODO: Turn this into an object that can return either seconds or a w/d/h/m/s
string.

=accessor B<aggregatetimeoriginalestimate>

Returns the aggregate time original estimate for the issue.

TODO: Turn this into an object that can return either seconds or a w/d/h/m/s
string.

=accessor B<aggregatetimespent>

Returns the aggregate time spent for the issue.

TODO: Turn this into an object that can return either seconds or a w/d/h/m/s
string.

=accessor B<assignee>

Returns the issue's assignee as a
L<JIRA::REST::Class::User|JIRA::REST::Class::User> object.

=accessor B<changelog>

Returns the issue's change log as a
L<JIRA::REST::Class::Issue::Changelog|JIRA::REST::Class::Issue::Changelog>
object.

=accessor B<comments>

Returns a list of the issue's comments as
L<JIRA::REST::Class::Issue::Comment|JIRA::REST::Class::Issue::Comment>
objects. If called in a scalar context, returns an array reference to the
list, not the number of elements in the list.

=accessor B<components>

Returns a list of the issue's components as
L<JIRA::REST::Class::Project::Component|JIRA::REST::Class::Project::Component>
objects. If called in a scalar context, returns an array reference to the
list, not the number of elements in the list.

=accessor B<component_count>

Returns a count of the issue's components.

=accessor B<created>

Returns the issue's creation date as a L<DateTime|DateTime> object.

=accessor B<creator>

Returns the issue's assignee as a
L<JIRA::REST::Class::User|JIRA::REST::Class::User> object.

=accessor B<description>

Returns the description of the issue.

=accessor B<duedate>

Returns the issue's due date as a L<DateTime|DateTime> object.

=accessor B<environment>

Returns the issue's environment as a hash reference.

TODO: Turn this into an object.

=accessor B<fixVersions>

Returns a list of the issue's fixVersions.

TODO: Turn this into a list of objects.

=accessor B<issuelinks>

Returns a list of the issue's links.

TODO: Turn this into a list of objects.

=accessor B<issuetype>

Returns the issue type as a
L<JIRA::REST::Class::Issue::Type|JIRA::REST::Class::Issue::Type> object.

=accessor B<labels>

Returns the issue's labels as an array reference.

=accessor B<lastViewed>

Returns the issue's last view date as a L<DateTime|DateTime> object.

=accessor B<parent>

Returns the issue's parent as a
L<JIRA::REST::Class::Issue|JIRA::REST::Class::Issue> object.

=accessor B<has_parent>

Returns a boolean indicating whether the issue has a parent.

=accessor B<priority>

Returns the issue's priority as a hash reference.

TODO: Turn this into an object.

=accessor B<progress>

Returns the issue's progress as a hash reference.

TODO: Turn this into an object.

=accessor B<project>

Returns the issue's project as a
L<JIRA::REST::Class::Project|JIRA::REST::Class::Project> object.

=accessor B<reporter>

Returns the issue's reporter as a
L<JIRA::REST::Class::User|JIRA::REST::Class::User> object.

=accessor B<resolution>

Returns the issue's resolution.

TODO: Turn this into an object.

=accessor B<resolutiondate>

Returns the issue's resolution date as a L<DateTime|DateTime> object.

=accessor B<status>

Returns the issue's status as a
L<JIRA::REST::Class::Issue::Status|JIRA::REST::Class::Issue::Status> object.

=accessor B<summary>

Returns the summary of the issue.

=accessor B<timeestimate>

Returns the time estimate for the issue.

TODO: Turn this into an object that can return either seconds or a w/d/h/m/s string.

=accessor B<timeoriginalestimate>

Returns the time original estimate for the issue.

TODO: Turn this into an object that can return either seconds or a w/d/h/m/s string.

=accessor B<timespent>

Returns the time spent for the issue.

TODO: Turn this into an object that can return either seconds or a w/d/h/m/s string.

=accessor B<timetracking>

Returns the time tracking of the issue as a
L<JIRA::REST::Class::Issue::TimeTracking|JIRA::REST::Class::Issue::TimeTracking>
object.

=accessor B<transitions>

Returns the valid transitions for the issue as a
L<JIRA::REST::Class::Issue::Transitions|JIRA::REST::Class::Issue::Transitions>
object.

=accessor B<updated>

Returns the issue's updated date as a L<DateTime|DateTime> object.

=accessor B<versions>

versions

=accessor B<votes>

votes

=accessor B<watches>

watches

=accessor B<worklog>

Returns the issue's change log as a
L<JIRA::REST::Class::Worklog|JIRA::REST::Class::Worklog> object.

=accessor B<workratio>

workratio

=accessor B<id>

Returns the issue ID.

=accessor B<key>

Returns the issue key.

=accessor B<self>

Returns the JIRA REST API's full URL for this issue.

=accessor B<url>

Returns the JIRA REST API's URL for this issue in a form used by
L<JIRA::REST::Class|JIRA::REST::Class>.

=for stopwords aggregatetimespent

=cut

__END__

{{
    require "pod/PodUtil.pm";
    $OUT .= PodUtil::include_stopwords();
    $OUT .= PodUtil::related_classes($plugin);
}}
