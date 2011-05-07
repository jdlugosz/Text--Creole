use 5.10.1;
use utf8;
use autodie;
package Text::Creole::InlineFormat;
use Moose;
use MooseX::ClassAttribute;
use namespace::autoclean;
use MooseX::Method::Signatures;
use MooseX::Types::Moose qw/HashRef ArrayRef RegexpRef /;

our $REGMARK;

=head1 NAME

Text::Creole::InlineFormat - a component of Text::Creole

=item format

Expands inline formatting codes and escapes out any special characters for the output stream.

=cut

method format (Str $type, Str $line)
 {
 # some types ignore formatting codes.  This could be generalized to select some codes used for each type, but now it's all or nothing.
 return $self->escape ($line, $type)  unless $self->formatting_enabled($type);
 return $self->format_table_row($line)  if $type eq 'tr';
 return $self->do_format ($line);
 }

my $named_link= q{ \s* (?<linkspec>[^|]*?) \s* (?:  (?<pipe>\|)  (?<name>.*?)  \s* )? };

sub build_parser_rules
 {
 my @parts;
 push @parts, [ 70, q{ \{{3} \s* (?<body>.*?) \s* \}{3} (*:nowiki)  } ];
 push @parts, [ 80, qr{ \{{2} $named_link \}{2} (*:image)   }xs ];
 push @parts, [ 90, qr{ \<{3} \s* (?<body>.*?) \s* \>{3} (*:placeholder)  }xs ];
 push @parts, [ 40, q{// \s* (?<body>(?: (?&link)  | . )*?)  \s*  (?: (?: (?<!~)//) | \Z)(*:italic) } ];   # special rules for //, skip any links in body.
 push @parts, [ 30, q{~ (?<body> (?&link)|.|\Z  ) (*:escape)} ];
 push @parts, [ 60, qr{\\\\ (*:break)}x ];
 return \@parts;
 }
    
method formulate_link_rule
 {
 # formulate the 'link' rule, which includes link_prefixes which are set after construction.
 # So this is used at the last moment before the parser is created.
 my $linkprefix= join "|", map { quotemeta($_) } @{$self->link_prefixes};
 my $blend= $self->get_parse_option('blended_links') ?
    q{ (?(<pipe>)|(?<blendsuffix> \w+)?  ) }
    : '';
 my $link= qr{
       (?<link>
          (?: \[{2} $named_link \]{2}  # explicit use of brackets  
             $blend  # blend suffix
             )  
          | (?:  (?<linkspec>(?: $linkprefix )://\S+?) 
             (?= [,.?!:;"']?   # ❝Single punctuation characters (,.?!:;"') at the end of URLs should not be considered part of the URL.❞
             (?: \Z|\s ) )  # since I used a lazy quantifier to allow the trailing punctuation, need to know how to end.
             )
       )(*:link)
    }x;
 return [ 10, $link ];
 }
 
method formulate_simples_rule
 {
 # formulate the 'simples' rule, which includes simple_format_tags which are set after construction.
 # So this is used at the last moment before the parser is created.
 my $simples= join "|", map { $_ eq '//' ? () : quotemeta($_) }  (keys %{$self->simple_format_tags});
 return [ 50, q{(?<simple> (?:} . $simples . q{))\s*(?<body>.*?) \s* (?: (?: (?<!~)\k<simple>) | \Z)  (*:simple)} ];
 }

method get_final_parser_rules
 {
 my $parser_rules= $self->parser_rules;
 push @$parser_rules, $self->formulate_link_rule, $self->formulate_simples_rule;
 return $parser_rules
 } 

method _build_parser_spec
 {
 my $parser_rules= $self->get_final_parser_rules;
 my $branches_string= join "\n | ", map {  
    my $x= $$_[1];
    ref $x ? $x : "(?: $x )"
    } (sort { $a->[0] <=> $b->[0] } @$parser_rules);
 my $ps= qr{(?<prematch>.*?)
     (?: $branches_string
	 | \Z (*:nada)  # must be the last branch
	) }xs;
 return $ps;
 }


method do_format (Str $line)
 {
 my @results;
 my $ps= $self->_parser_spec;
 while ($line =~ /$ps/g) {
    my %captures= %+;
	my $regmark= $REGMARK;
    my $prematch= $captures{prematch};
	push @results, $self->escape($self->filter($prematch))  unless length($prematch)==0;
    unless ($regmark eq 'nada') {
       my $meth= "grammar_branch_$regmark";
       push @results, $self->$meth (\%captures);
       }
    }
 return join ('', @results);
 }

=item grammar branch methods

The function corresponding to the matched branch is called after identifying a match from the inline formatting grammar.  Extend it to add processing for any new branches you add to the grammar.

It can return a list of strings that are concatenated by the caller.

=cut

method grammar_branch_simple (HashRef $captures)
 {
 my $body= $$captures{body};
 my $style= $$captures{simple};
 return $self->simple_format ($style, $body);
 }

 method grammar_branch_italic (HashRef $captures)
 {
 my $body= $$captures{body};
 return $self->simple_format ('//', $body);
 }
 
method grammar_branch_break (HashRef $captures)
 {
 return $self->format_tag ($self->get_tag_data('br'), undef);
 }

method grammar_branch_link (HashRef $captures)
 {
 my $name=
    defined($$captures{blendsuffix}) 
    ? $$captures{linkspec} . $$captures{blendsuffix}
    :  $$captures{name};
 return $self->process_link_body ($$captures{linkspec}, $name);
 }

method grammar_branch_nowiki (HashRef $captures)
 {
 # interesting in what it doesn't do.
 return $self->escape($$captures{body});
 } 

method grammar_branch_escape (HashRef $captures)
 {
 my $body= $$captures{body};
 $body= "~$body"  if $body =~ /^\s*$/s;   # keep it if followed by blank or line-end
 return $self->escape($body);
 }

method grammar_branch_image (HashRef $captures)
 {
 return $self->process_image ($$captures{linkspec}, $$captures{name});
 }

method grammar_branch_placeholder (HashRef $captures)
 {
 my $body= $$captures{body};
 if ($body =~ /^[Bb]:/) {
    # oops, this was supposed to be on a line by itself
    return $self->format_tag ([ 'span', 'bad-block-placeholder' ], $self->escape("<<<$body>>>") );
    }
 my $func= $self->placeholder_callback;
 if (defined $func) {
    my @results= $func->($self->tag_formatter, $body);
    return @results  if scalar @results > 0;
    }
 return $self->format_tag ([ 'span', 'placeholder' ], $self->escape("<<<$body>>>") );
 }
 
 
method process_link_body (Str $linkspec, Maybe[Str] $origname)
 {
 my ($href, $name, $type)= $self->link_mapper->($linkspec, $origname);
 $name //= $linkspec;
 $type //= 'a';
 # >> TODO: either recursively process Name, or just escape it.
 return $self->format_tag ($self->get_tag_data($type), $name, $self->escape($href));
 }

method process_image (Str $link, $alt)
 {
 $alt //= 'image';
 my $href= $link;   # TODO: map strings to full URL
 return $self->format_tag ($self->get_tag_data('img'), $href, $alt); 
 }
 
 
 
=item simple_format

This handles formatting of the so-called "simple" format codes.  These have the same sequence opening and closing, and the built-in ones are bold and italics.  These are extensible by the caller, so this looks up the tag in a configuration table.

=cut


has simple_format_tags => (
   is => 'rw',
   isa => HashRef,
   default => sub { {
      '**' => ['strong'],  # tag,class pairs with class optional.
      '//' => ['em']
      }} ,
   );
   
method simple_format (Str $style, Str $body)
 {
 $body= $self->do_format($body);
 return $self->format_tag ($self->simple_format_tags->{$style}, $body);
 }


method format_table_row (Str $line)
 {
 my @cells= split (/\s*(?:\|\s*|\Z)/, $line);
 shift @cells;  #leading pipe always creates a leading empty value
 return join '', map {
    my $s= $_;
    my $tag= 'td';
    if ($s =~ /^=\s*(.*)$/) {
       $s= $1;
       $tag= 'th';
       }
    $self->format_tag ($self->get_tag_data($tag), $self->do_format($s));
    } @cells;
 }

method formatting_enabled (Str $type)
 {
 given ($type) {
    when (/^h/) {
	   return 0;   # will make configurable.
	   }
	when ('pre') { return 0; }
    default { return 1; }
    }
 }

has  tag_data => (
   is => 'bare',
   traits => ['Hash'],
   isa => HashRef,
   handles => {
      get_tag_data => 'get'
	  }, 
   required => 1,
   );

has tag_formatter => (
    is => 'ro',
    handles => [ qw( format_tag escape filter link_prefixes)],
    required => 1,
    weak_ref => 1,  # normally points back to parent Creole object
    );

 has config_keeper => (
    is => 'ro',
    handles => [ qw( placeholder_callback link_mapper image_mapper)],
    required => 1,
    weak_ref => 1,  # normally points back to parent Creole object
    );

 # Options understood here:
# 'entity-passthrough-PRE'  Bool - passes through entities in PRE blocks.
has parse_option => (
   is => 'bare',
   traits => ['Hash'],
   isa => 'HashRef',
   handles => {
      get_parse_option => 'get'
	  },
   );

class_has parser_rules => (
   is => 'rw',
   isa => ArrayRef[ArrayRef],
   builder => 'build_parser_rules',
   );
    
has _parser_spec => (
   is => 'rw',
   isa => RegexpRef,
   init_arg => undef,
   builder => '_build_parser_spec',
   lazy => 1,
   );



__PACKAGE__->meta->make_immutable;
