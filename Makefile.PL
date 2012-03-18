use 5.008;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'POE::Component::Runner',
    VERSION_FROM => 'lib/POE/Component/Runner.pm',
    PREREQ_PM    => {
        'POE'                      => 0,
        'POE::Session'             => 0,
        'POE::Wheel::Run'          => 0,
        'POE::Component::DirWatch' => 0,
        'File::Copy'               => 0,
        'Data::GUID'               => 0,
        'Data::Dumper'             => 0,
    },
    (   $] >= 5.005
        ? ( ABSTRACT_FROM => 'lib/POE/Component/Runner.pm',
            AUTHOR        => 'Dylan Doxey <dylan.doxey@gmail.com>'
            )
        : ()
    ),
);
