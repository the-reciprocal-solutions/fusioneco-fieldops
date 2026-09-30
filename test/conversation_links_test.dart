import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/conversation/conversation_links.dart';
import 'package:technician_portal/core/utils/notification_route.dart';
import 'package:technician_portal/domain/app_notification.dart';

AppNotification _n({String? entityType, String? entityId, String? link, String? category, String title = 'x'}) =>
    AppNotification(
      id: 'n',
      title: title,
      message: '',
      type: 'info',
      entityType: entityType,
      entityId: entityId,
      link: link,
      category: category,
    );

void main() {
  group('conversation notifications (server notify.ts)', () {
    test('snag reply with a web admin link → the snag thread, scrolled to the message', () {
      expect(
        routeForNotification(_n(
          entityType: 'conversation:snag:reply',
          entityId: 'snag-uuid',
          link: '/facility-management/snags?snag=snag-uuid&message=m-1',
        )),
        '/conversations/snag/snag-uuid?message=m-1',
      );
    });

    test('work order mention → its detail on the Comments tab', () {
      expect(
        routeForNotification(_n(
          entityType: 'conversation:work_order:mention',
          entityId: 'wo-uuid',
          link: '/facility-management/work-order/view/wo-uuid?tab=comments&message=m-2',
        )),
        '/orders/work-order/wo-uuid?tab=comments&message=m-2',
      );
    });

    test('other records open the stand-alone thread', () {
      expect(
        routeForNotification(_n(entityType: 'conversation:permit:message', entityId: 'p-1', link: '/facility-management/permits/p-1?message=m')),
        '/conversations/permit/p-1?message=m',
      );
    });

    test('a technician link works too (message id kept)', () {
      expect(
        routeForNotification(_n(entityType: 'conversation:snag:reply', entityId: 's', link: '/technician/snags/s?message=m9')),
        '/conversations/snag/s?message=m9',
      );
    });

    test('no entity id: falls back to the web link', () {
      expect(
        conversationRouteFor(entityType: 'conversation:asset:reply', link: '/facility-management/assets/view/a-1?message=z'),
        '/conversations/asset/a-1?message=z',
      );
    });

    test('the old AI-chat type still opens nothing', () {
      expect(routeForNotification(_n(entityType: 'conversation', entityId: 'c')), isNull);
    });
  });

  group('schedule / session notifications (server C2/C3)', () {
    test('schedule with the technician link → that schedule in My schedules', () {
      expect(
        routeForNotification(_n(entityType: 'schedule:failed', entityId: 'sch-1', link: '/technician/schedules/sch-1')),
        '/schedules/sch-1',
      );
    });

    test('schedule done linking the origin thread → the thread', () {
      expect(
        routeForNotification(_n(
          entityType: 'schedule:done',
          entityId: 'sch-1',
          link: '/facility-management/work-order/view/wo-1?tab=comments&message=r-1',
        )),
        '/orders/work-order/wo-1?tab=comments&message=r-1',
      );
    });

    test('schedule with a web-only link → My schedules focused on it', () {
      expect(
        routeForNotification(_n(entityType: 'schedule:started', entityId: 'sch-2', link: '/flow-agents/schedules?schedule=sch-2')),
        '/schedules?focus=sch-2',
      );
    });

    test('session done with a technician link → the snag (which opens the thread)', () {
      expect(
        routeForNotification(_n(entityType: 'session:done', entityId: 's', link: '/technician/snags/s?message=r')),
        '/snags/s?message=r',
      );
    });
  });

  test('existing routing is untouched', () {
    expect(routeForNotification(_n(entityType: 'WorkOrder', entityId: 'wo-1')), '/orders/work-order/wo-1');
    expect(routeForNotification(_n(link: '/technician/snags/abc')), '/snags/abc');
  });

  test('noticeFamily picks the icon family', () {
    expect(noticeFamily('conversation:snag:reply', category: 'ai_conversation'), NoticeFamily.agentReply);
    expect(noticeFamily('conversation:snag:reply', category: 'user'), NoticeFamily.conversation);
    expect(noticeFamily('conversation:snag:mention'), NoticeFamily.mention);
    expect(noticeFamily('schedule:done'), NoticeFamily.scheduleDone);
    expect(noticeFamily('schedule:failed'), NoticeFamily.scheduleFailed);
    expect(noticeFamily('session:started'), NoticeFamily.scheduleStarted);
    expect(noticeFamily('WorkOrder'), NoticeFamily.other);
  });
}
