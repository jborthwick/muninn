#!/usr/bin/env python3
from pbxproj import XcodeProject

# Path to the project file
project_path = '/Users/apisoni/dev/podcash/Podcash.xcodeproj/project.pbxproj'

# Load the project
project = XcodeProject.load(project_path)

# File to add
file_path = 'Podcash/Views/Episode/EpisodeDetailView.swift'

# Find the main target (typically the first one, or we can search by name)
targets = project.objects.get_targets()
main_target = None
for target in targets:
    if target.name == 'Podcash':
        main_target = target
        break

if main_target is None and targets:
    main_target = targets[0]
    print(f"Using target: {main_target.name}")

if main_target:
    # Add the file to the project and target
    # The add_file method will create the file reference and add it to the build phase
    result = project.add_file(
        file_path,
        parent=project.get_or_create_group('Episode', parent=project.get_or_create_group('Views', parent=project.get_or_create_group('Podcash'))),
        target_name=main_target.name
    )
    
    if result:
        print(f"Successfully added {file_path} to project")
        project.save()
        print("Project saved successfully")
    else:
        print("Failed to add file - it may already exist in the project")
else:
    print("No target found in the project")
