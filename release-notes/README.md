# Release notes

Write the notes for a version as `release-notes/<version>.md`, for example
`release-notes/1.0.1.md`, before running:

```sh
scripts/release.sh --version 1.0.1 --keep-installs --publish
```

The file becomes the **What's new** section of the GitHub Release page.
`scripts/github-release.sh` adds the download link, the Terminal install line,
the checksum and the list of changes since the previous tag around it. Plain
Markdown; start with bullet points, no top-level heading.
