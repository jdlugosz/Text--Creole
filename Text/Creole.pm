use 5.10.1;
use utf8;
use autodie;
package Text::Creole;
use Moose;
use namespace::autoclean;
use MooseX::Method::Signatures;

use Text::Creole::LineBlocker;
use Text::Creole::InlineFormat;

=head1 NAME

Text::Creole - Parse Wiki Creole input and produce XHTML.

=cut


has line_blocker => (
   is => 'ro',
   default => sub { Text::Creole::LineBlocker->new; },
   handles => [qw( input_some input_all)],
   );

has inline_formatter => (
   is => 'ro',
   default => sub { Text::Creole::InlineFormat->new; }
   );

   
method output()
 {
 return map { 
    my $item= $_;
    $self->block_format($$item[0], $self->inline_formatter->format(@$item)) 
    }  ($self->line_blocker->output);
 }
 
method block_format (Str $type, Str $text)
 {
 return "BLOCK($type) $text";
 }
 
 
 __PACKAGE__->meta->make_immutable;
