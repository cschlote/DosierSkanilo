Name:           dosierskanilo
Version:        26.9.2
Release:        1%{?dist}
Summary:        Blob-centric media and archive file scanner
License:        CC-BY-NC-SA
URL:            https://github.com/cschlote/DosierSkanilo
Source0:        %{url}/archive/refs/tags/v%{version}.tar.gz

BuildRequires:  ldc
BuildRequires:  dub
BuildRequires:  mediainfo-devel
Requires:       mediainfo
Requires:       file
Requires:       unzip
Requires:       tar
Requires:       unrar
Requires:       p7zip

%description
DosierSkanilo scans files, calculates checksums, extracts metadata and stores
JSON results for duplicate detection.

%prep
%autosetup -n DosierSkanilo-%{version}

%build
DC=ldc2 dub build --build=release --compiler=ldc2 --config=cli

%install
install -Dpm0755 build/bin/dosierskanilo %{buildroot}%{_bindir}/dosierskanilo

%files
%{_bindir}/dosierskanilo
