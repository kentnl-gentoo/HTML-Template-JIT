use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'		=> 'HTML::Template::JIT',
    'VERSION_FROM'	=> 'JIT.pm', # finds $VERSION
    'PREREQ_PM'		=> {
			    Inline::C   => 0,
			    Inline      => 0.43,
			    File::Spec  => 0,
			    File::Path  => 0,
			    Digest::MD5 => 0,
			    Test::More  => 0,
			   },
);
