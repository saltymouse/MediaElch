add_library(
  mediaelch_ui_notifications OBJECT NotificationBox.cpp Notificator.cpp
)

if(APPLE)
  target_sources(mediaelch_ui_notifications PRIVATE MacNotificationHandler.mm)
  if(CMAKE_CXX_COMPILER_ID STREQUAL "AppleClang")
    set_source_files_properties(
      MacNotificationHandler.mm PROPERTIES COMPILE_OPTIONS
                                           "-fno-objc-msgsend-selector-stubs"
    )
  endif()
endif()

target_link_libraries(
  mediaelch_ui_notifications PRIVATE Qt${QT_VERSION_MAJOR}::Widgets
)
mediaelch_post_target_defaults(mediaelch_ui_notifications)
