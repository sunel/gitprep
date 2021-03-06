package Gitprep::API;
use Mojo::Base -base;

use Digest::MD5 'md5_hex';
use Text::Markdown::Hoedown qw(HOEDOWN_EXT_FENCED_CODE HOEDOWN_EXT_TABLES HOEDOWN_EXT_NO_INTRA_EMPHASIS);

has 'cntl';

sub api_delete_issue_message {
  my ($self, $issue_message_row_id, $user_id) = @_;
  
  my $issue_message = $self->app->dbi->model('issue_message')->select(
    {user => ['id']}, where => {'issue_message.row_id' => $issue_message_row_id}
  )->one;
  
  my $session_user_id = $self->session_user_id;

  my $is_my_project = $user_id eq $session_user_id;
  my $is_my_comment = $issue_message->{'user.id'} eq $session_user_id;
  my $can_modify = $is_my_project || $is_my_comment;
  
  my $json;
  if ($can_modify) {
    $self->app->dbi->model('issue_message')->delete(
      where => {row_id => $issue_message_row_id}
    );
    
    $json = {success => 1};
  }
  else {
    $json = {success => 0};
  }
  
  return $json;
}

sub add_issue_message {
  my ($self, $user_id, $project_id, $number, $message) = @_;
  
  $self->app->dbi->connector->txn(sub {
    my $issue_row_id = $self->app->dbi->model('issue')->select(
      'issue.row_id',
      where => {
        'project__user.id' => $user_id,
        'project.id' => $project_id,
        number => $number
      }
    )->value;

    # Issue message number
    my $issue_message_number = $self->app->dbi->model('issue_message')->select(
      'max(number)',
      where => {issue => $issue_row_id}
    )->value;
    $issue_message_number++;

    # New issue message
    my $now_tm = Time::Moment->now_utc;
    my $now_epoch = $now_tm->epoch;
    my $session_user_row_id = $self->session_user_row_id;
    my $new_issue_message = {
      issue => $issue_row_id,
      number => $issue_message_number,
      message => $message,
      create_time => $now_epoch,
      update_time => $now_epoch,
      user => $session_user_row_id
    };
    
    $self->app->dbi->model('issue_message')->insert($new_issue_message);
  });
}

sub markdown {
  my ($self, $text) = @_;

  my $text_e = Text::Markdown::Hoedown::markdown(
    $text, extensions => HOEDOWN_EXT_FENCED_CODE|HOEDOWN_EXT_TABLES|HOEDOWN_EXT_NO_INTRA_EMPHASIS
  );
  
  return $text_e;
}

sub age_string {
  my ($self, $epoch_time) = @_;
  
  my $age = time - $epoch_time;
  
  my $age_string = $self->cntl->app->git->_age_string($age);
  
  return $age_string;
}

sub get_user_row_id {
  my ($self, $user_id) = @_;
  
  my $user_row_id = $self->app->dbi->model('user')->select('row_id', where => {id => $user_id})->value;
  
  return $user_row_id;
}

sub get_project_row_id {
  my ($self, $user_id, $project_id) = @_;
  
  my $user_row_id = $self->app->dbi->model('user')->select('row_id', where => {id => $user_id})->value;
  my $project_row_id = $self->app->dbi->model('project')->model('project')->select(
    'row_id',
    where => {user => $user_row_id, id => $project_id}
  )->value;
  
  return $project_row_id;
}

sub app { shift->cntl->app }

sub encrypt_password {
  my ($self, $password) = @_;
  
  my $salt;
  $salt .= int(rand 10) for (1 .. 40);
  my $password_encryped = md5_hex md5_hex "$salt$password";
  
  return ($password_encryped, $salt);
}

sub check_password {
  my ($self, $password, $salt, $password_encrypted) = @_;
  
  return unless defined $password && $salt && $password_encrypted;
  
  return md5_hex(md5_hex "$salt$password") eq $password_encrypted;
}

sub check_user_and_password {
  my ($self, $user_id, $password) = @_;
  
  my $row
    = $self->app->dbi->model('user')->select(['password', 'salt'], where => {id => $user_id})->one;
  
  return unless $row;
  
  my $is_valid = $self->check_password(
    $password,
    $row->{salt},
    $row->{password}
  );
  
  return $is_valid;
}

sub is_collaborator {
  my ($self, $collaborator_id, $user_id, $project_id) = @_;
  
  my $user_row_id = $self->get_user_row_id($user_id);
  my $project_row_id = $self->app->dbi->model('project')->select(
    where => {user => $user_row_id, id => $project_id}
  )->value;
  my $collaborator_row_id = $self->get_user_row_id($collaborator_id);
  
  my $row = $self->app->dbi->model('collaboration')->select(
    where => {project => $project_row_id, user => $collaborator_row_id}
  )->one;
  
  return $row ? 1 : 0;
}

sub can_access_private_project {
  my ($self, $user_id, $project_id) = @_;

  my $session_user_row_id = $self->cntl->session('user_row_id');
  return unless defined $session_user_row_id;
  
  my $session_user_id = $self->app->dbi->model('user')->select(
    'id', where => {row_id => $session_user_row_id}
  )->value;
  
  my $is_valid =
    ($user_id eq $session_user_id || $self->is_collaborator($session_user_id, $user_id, $project_id))
    && $self->logined;
  
  return $is_valid;
}

sub can_write_access {
  my ($self, $session_user_id, $user_id, $project_id) = @_;
  
  my $can_write_access
    = length $session_user_id &&
    (
      $session_user_id eq $user_id
      || $self->is_collaborator($session_user_id, $user_id, $project_id)
    );
  
  return $can_write_access;
}

sub new {
  my ($class, $cntl) = @_;

  my $self = $class->SUPER::new(cntl => $cntl);
  
  return $self;
}

sub logined_admin {
  my $self = shift;

  # Controler
  my $c = $self->cntl;
  
  # Check logined as admin
  my $session_user_id = $self->session_user_id;
  
  return $self->app->manager->is_admin($session_user_id) && $self->logined($session_user_id);
}

sub session_user_row_id {
  my $self = shift;
  
  my $session_user_row_id = $self->cntl->session('user_row_id');
  
  return $session_user_row_id;
}

sub session_user_id {
  my $self = shift;
  
  my $session_user_row_id = $self->cntl->session('user_row_id');
  my $session_user_id = $self->app->dbi->model('user')->select(
    'id', where => {row_id => $session_user_row_id}
  )->value;
  
  return $session_user_id;
}

sub logined {
  my ($self, $user_id) = @_;
  
  my $c = $self->cntl;
  my $dbi = $c->app->dbi;
  
  my $session_user_row_id = $c->session('user_row_id');
  my $session_user_id = $self->session_user_id;
  my $password = $c->session('password');
  return unless defined $password;
  
  my $correct_password = $dbi->model('user')->select(
    'password',
    where => {row_id => $session_user_row_id}
  )->value;
  return unless defined $correct_password;
  
  my $logined;
  if (defined $user_id) {
    $logined = $user_id eq $session_user_id && $password eq $correct_password;
  }
  else {
    $logined = $password eq $correct_password
  }
  
  return $logined;
}

sub params {
  my $self = shift;
  
  my $c = $self->cntl;
  
  my %params;
  for my $name ($c->param) {
    my @values = $c->param($name);
    if (@values > 1) {
      $params{$name} = \@values;
    }
    elsif (@values) {
      $params{$name} = $values[0];
    }
  }
  
  return \%params;
}

1;

