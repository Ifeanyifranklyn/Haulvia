import { Stack, useLocalSearchParams } from 'expo-router';
import { useMemo } from 'react';
import {
    Alert,
    Pressable,
    SafeAreaView,
    ScrollView,
    StatusBar,
    StyleSheet,
    Text,
    View,
} from 'react-native';

type ServiceType = 'expedited' | 'flex';

type TimelineEvent = {
  id: string;
  title: string;
  description: string;
  time?: string;
  state: 'completed' | 'current' | 'pending';
};

function firstParam(value: string | string[] | undefined) {
  return Array.isArray(value) ? value[0] : value;
}

function formatCurrency(value: number | null) {
  if (value === null) {
    return 'Not available';
  }

  return new Intl.NumberFormat('en-CA', {
    style: 'currency',
    currency: 'CAD',
    minimumFractionDigits: 2,
  }).format(value);
}

export default function CustomerLoadDetailsScreen() {
  const params = useLocalSearchParams<{
    loadId?: string;
    serviceType?: ServiceType;
    price?: string;
    pickupLocation?: string;
    deliveryLocation?: string;
    description?: string;
    category?: string;
    quantity?: string;
    vehicleRequirement?: string;
    pickupDate?: string;
    deliveryDate?: string;
  }>();

  const loadNumber =
    firstParam(params.loadId) ?? 'HV-20260722-0001';

  const serviceType: ServiceType =
    firstParam(params.serviceType) === 'expedited'
      ? 'expedited'
      : 'flex';

  const isExpedited = serviceType === 'expedited';

  const selectedPrice = useMemo(() => {
    const parsedPrice = Number(firstParam(params.price));

    return Number.isFinite(parsedPrice) ? parsedPrice : null;
  }, [params.price]);

  const pickupLocation =
    firstParam(params.pickupLocation) ??
    'Pickup location will appear here';

  const deliveryLocation =
    firstParam(params.deliveryLocation) ??
    'Delivery location will appear here';

  const description =
    firstParam(params.description) ?? 'Posted load';

  const category =
    firstParam(params.category) ?? 'General load';

  const quantity =
    firstParam(params.quantity) ?? '1';

  const vehicleRequirement =
    firstParam(params.vehicleRequirement) ?? 'Not specified';

  const pickupDate =
    firstParam(params.pickupDate) ?? 'To be confirmed';

  const deliveryDate =
    firstParam(params.deliveryDate) ?? 'To be confirmed';

  const timeline = useMemo<TimelineEvent[]>(
    () => [
      {
        id: 'posted',
        title: 'Load posted',
        description:
          'The load was published successfully and is visible in your account.',
        time: 'Just now',
        state: 'completed',
      },
      {
        id: 'pricing',
        title: 'Pricing confirmed',
        description: isExpedited
          ? 'The expedited fixed price was recorded for driver matching.'
          : 'Your Flex budget was recorded for driver offers.',
        time: 'Just now',
        state: 'completed',
      },
      {
        id: 'matching',
        title: isExpedited
          ? 'Priority driver matching'
          : 'Looking for drivers',
        description: isExpedited
          ? 'Nearby qualified drivers are being prioritized for this load.'
          : 'Qualified drivers are being notified and can submit offers.',
        state: 'current',
      },
      {
        id: 'selected',
        title: 'Driver selected',
        description:
          'The selected driver and vehicle will appear here.',
        state: 'pending',
      },
      {
        id: 'pickup',
        title: 'Pickup confirmed',
        description:
          'Pickup verification will be recorded after collection.',
        state: 'pending',
      },
      {
        id: 'delivered',
        title: 'Delivered',
        description:
          'Delivery confirmation and proof of delivery will appear here.',
        state: 'pending',
      },
    ],
    [isExpedited],
  );

  const handleEditLoad = () => {
    Alert.alert(
      'Editing is coming next',
      'This action will reopen the posting flow with the saved load details.',
    );
  };

  const handleCancelLoad = () => {
    Alert.alert(
      'Cancel this load?',
      'The load will be removed from driver matching. No payment has been taken.',
      [
        {
          text: 'Keep Load',
          style: 'cancel',
        },
        {
          text: 'Cancel Load',
          style: 'destructive',
          onPress: () => {
            Alert.alert(
              'Load cancellation',
              'Backend cancellation will be connected later.',
            );
          },
        },
      ],
    );
  };

  const handleContactSupport = () => {
    Alert.alert(
      'Haulvia Support',
      `Support will receive the reference number ${loadNumber} automatically.`,
    );
  };

  return (
    <>
      <Stack.Screen
        options={{
          title: 'Load details',
          headerBackTitle: 'Back',
        }}
      />

      <SafeAreaView style={styles.container}>
        <StatusBar barStyle="dark-content" />

        <ScrollView
          contentContainerStyle={styles.content}
          showsVerticalScrollIndicator={false}
        >
          <View style={styles.headingRow}>
            <View style={styles.headingTextContainer}>
              <Text style={styles.referenceLabel}>
                SHIPMENT NUMBER
              </Text>

              <Text
                numberOfLines={1}
                adjustsFontSizeToFit
                minimumFontScale={0.85}
                style={styles.referenceNumber}
              >
                {loadNumber}
              </Text>

              <Text style={styles.postedTime}>
                Posted just now
              </Text>
            </View>
          </View>

          <View style={styles.statusBadgeRow}>
            <View style={styles.statusBadge}>
              <View style={styles.statusDot} />
              <Text style={styles.statusBadgeText}>
                LOOKING FOR DRIVERS
              </Text>
            </View>
          </View>

          <View style={styles.routeCard}>
            <View style={styles.routeHeader}>
              <Text style={styles.sectionTitle}>Route</Text>
              <Text style={styles.routeStatus}>ACTIVE</Text>
            </View>

            <View style={styles.routeItem}>
              <View style={styles.routeVisual}>
                <View style={styles.pickupDot} />
                <View style={styles.routeLine} />
              </View>

              <View style={styles.routeTextContainer}>
                <Text style={styles.routeLabel}>PICKUP</Text>
                <Text style={styles.routeValue}>
                  {pickupLocation}
                </Text>
                <Text style={styles.routeDate}>
                  {pickupDate}
                </Text>
              </View>
            </View>

            <View style={styles.routeItem}>
              <View style={styles.routeVisual}>
                <View style={styles.deliveryDot} />
              </View>

              <View style={styles.routeTextContainer}>
                <Text style={styles.routeLabel}>DELIVERY</Text>
                <Text style={styles.routeValue}>
                  {deliveryLocation}
                </Text>
                <Text style={styles.routeDate}>
                  {deliveryDate}
                </Text>
              </View>
            </View>
          </View>

          <View style={styles.summaryCard}>
            <View style={styles.sectionHeaderRow}>
              <Text style={styles.sectionTitle}>Load summary</Text>

              <Pressable
                accessibilityLabel="Edit posted load"
                accessibilityRole="button"
                onPress={handleEditLoad}
                style={({ pressed }) => [
                  styles.textButton,
                  pressed && styles.pressed,
                ]}
              >
                <Text style={styles.textButtonLabel}>Edit</Text>
              </Pressable>
            </View>

            <Text style={styles.loadDescription}>
              {description}
            </Text>

            <View style={styles.tagRow}>
              <View style={styles.tag}>
                <Text style={styles.tagText}>{category}</Text>
              </View>

              <View style={styles.tag}>
                <Text style={styles.tagText}>
                  {quantity} {quantity === '1' ? 'item' : 'items'}
                </Text>
              </View>

              <View style={styles.tag}>
                <Text style={styles.tagText}>
                  {vehicleRequirement}
                </Text>
              </View>
            </View>

            <View style={styles.divider} />

            <View style={styles.serviceRow}>
              <View>
                <Text style={styles.detailLabel}>SERVICE</Text>
                <Text style={styles.detailValue}>
                  {isExpedited ? 'Expedited' : 'Flex'}
                </Text>
              </View>

              <View style={styles.priceContainer}>
                <Text style={styles.detailLabel}>
                  {isExpedited ? 'FIXED PRICE' : 'POSTED BUDGET'}
                </Text>
                <Text style={styles.priceValue}>
                  {formatCurrency(selectedPrice)}
                </Text>
              </View>
            </View>

            <Text style={styles.priceNote}>
              {isExpedited
                ? 'Qualified drivers are being matched at the displayed price.'
                : 'Drivers can accept your budget or submit a counteroffer.'}
            </Text>
          </View>

          <View style={styles.offersCard}>
            <View style={styles.sectionHeaderRow}>
              <View>
                <Text style={styles.sectionTitle}>
                  Driver offers
                </Text>
                <Text style={styles.sectionSubtitle}>
                  0 offers received
                </Text>
              </View>

              <View style={styles.liveBadge}>
                <View style={styles.liveDot} />
                <Text style={styles.liveBadgeText}>LIVE</Text>
              </View>
            </View>

            <View style={styles.emptyOfferState}>
              <View style={styles.searchIcon}>
                <Text style={styles.searchIconText}>⌁</Text>
              </View>

              <Text style={styles.emptyOfferTitle}>
                No offers yet
              </Text>

              <Text style={styles.emptyOfferDescription}>
                {isExpedited
                  ? 'Haulvia is prioritizing nearby qualified drivers for this load.'
                  : 'Qualified nearby drivers are being notified. We’ll alert you when an offer arrives.'}
              </Text>
            </View>
          </View>

          <View style={styles.timelineCard}>
            <Text style={styles.sectionTitle}>Load timeline</Text>

            <Text style={styles.sectionSubtitle}>
              A permanent record of important shipment activity.
            </Text>

            <View style={styles.timelineList}>
              {timeline.map((event, index) => {
                const isLast = index === timeline.length - 1;

                return (
                  <View key={event.id} style={styles.timelineItem}>
                    <View style={styles.timelineVisual}>
                      <View
                        style={[
                          styles.timelineDot,
                          event.state === 'completed' &&
                            styles.timelineDotCompleted,
                          event.state === 'current' &&
                            styles.timelineDotCurrent,
                          event.state === 'pending' &&
                            styles.timelineDotPending,
                        ]}
                      >
                        {event.state === 'completed' ? (
                          <Text style={styles.timelineCheck}>✓</Text>
                        ) : event.state === 'current' ? (
                          <View style={styles.timelineCurrentInner} />
                        ) : null}
                      </View>

                      {!isLast ? (
                        <View style={styles.timelineConnector} />
                      ) : null}
                    </View>

                    <View
                      style={[
                        styles.timelineText,
                        !isLast && styles.timelineTextWithSpacing,
                      ]}
                    >
                      <View style={styles.timelineTitleRow}>
                        <Text
                          style={[
                            styles.timelineTitle,
                            event.state === 'pending' &&
                              styles.timelineTitlePending,
                          ]}
                        >
                          {event.title}
                        </Text>

                        {event.time ? (
                          <Text style={styles.timelineTime}>
                            {event.time}
                          </Text>
                        ) : null}
                      </View>

                      <Text style={styles.timelineDescription}>
                        {event.description}
                      </Text>
                    </View>
                  </View>
                );
              })}
            </View>
          </View>

          <View style={styles.actionsCard}>
            <Text style={styles.sectionTitle}>Load actions</Text>

            <Pressable
              accessibilityLabel="Contact Haulvia support"
              accessibilityRole="button"
              onPress={handleContactSupport}
              style={({ pressed }) => [
                styles.supportButton,
                pressed && styles.supportButtonPressed,
              ]}
            >
              <Text style={styles.supportButtonText}>
                Contact support
              </Text>
            </Pressable>

            <Pressable
              accessibilityLabel="Cancel posted load"
              accessibilityRole="button"
              onPress={handleCancelLoad}
              style={({ pressed }) => [
                styles.cancelButton,
                pressed && styles.cancelButtonPressed,
              ]}
            >
              <Text style={styles.cancelButtonText}>
                Cancel load
              </Text>
            </Pressable>
          </View>

          <Text style={styles.footerText}>
            Use {loadNumber} when contacting support about this load.
          </Text>
        </ScrollView>
      </SafeAreaView>
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: '#F7F9FC',
    flex: 1,
  },
  content: {
    paddingBottom: 44,
    paddingHorizontal: 20,
    paddingTop: 24,
  },
  headingRow: {
    flexDirection: 'row',
  },
  headingTextContainer: {
    flex: 1,
  },
  referenceLabel: {
    color: '#6B7280',
    fontSize: 11,
    fontWeight: '800',
    letterSpacing: 1,
  },
  referenceNumber: {
    color: '#111827',
    fontSize: 28,
    fontWeight: '900',
    letterSpacing: 0.2,
    marginTop: 6,
  },
  statusBadgeRow: {
    alignItems: 'flex-start',
    marginTop: 8,
  },
  statusBadge: {
    alignItems: 'center',
    alignSelf: 'flex-start',
    backgroundColor: '#EFF6FF',
    borderColor: '#BFDBFE',
    borderRadius: 999,
    borderWidth: 1,
    flexDirection: 'row',
    paddingHorizontal: 10,
    paddingVertical: 8,
  },
  statusDot: {
    backgroundColor: '#1D4ED8',
    borderRadius: 999,
    height: 7,
    marginRight: 6,
    width: 7,
  },
  statusBadgeText: {
    color: '#1D4ED8',
    fontSize: 9,
    fontWeight: '900',
    letterSpacing: 0.45,
  },
  postedTime: {
    color: '#6B7280',
    fontSize: 13,
    marginTop: 7,
  },
  routeCard: {
    backgroundColor: '#FFFFFF',
    borderColor: '#E2E7EF',
    borderRadius: 22,
    borderWidth: 1,
    marginTop: 22,
    padding: 18,
  },
  routeHeader: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 20,
  },
  routeStatus: {
    color: '#16A34A',
    fontSize: 10,
    fontWeight: '900',
    letterSpacing: 0.8,
  },
  sectionTitle: {
    color: '#111827',
    fontSize: 19,
    fontWeight: '900',
  },
  sectionSubtitle: {
    color: '#6B7280',
    fontSize: 12,
    lineHeight: 18,
    marginTop: 4,
  },
  routeItem: {
    flexDirection: 'row',
  },
  routeVisual: {
    alignItems: 'center',
    marginRight: 14,
    width: 18,
  },
  pickupDot: {
    backgroundColor: '#1D4ED8',
    borderRadius: 999,
    height: 12,
    width: 12,
  },
  routeLine: {
    backgroundColor: '#CBD5E1',
    flex: 1,
    marginVertical: 5,
    minHeight: 48,
    width: 2,
  },
  deliveryDot: {
    backgroundColor: '#16A34A',
    borderRadius: 3,
    height: 12,
    width: 12,
  },
  routeTextContainer: {
    flex: 1,
    paddingBottom: 20,
  },
  routeLabel: {
    color: '#6B7280',
    fontSize: 10,
    fontWeight: '900',
    letterSpacing: 0.8,
  },
  routeValue: {
    color: '#111827',
    fontSize: 15,
    fontWeight: '800',
    lineHeight: 21,
    marginTop: 4,
  },
  routeDate: {
    color: '#6B7280',
    fontSize: 12,
    marginTop: 4,
  },
  summaryCard: {
    backgroundColor: '#FFFFFF',
    borderColor: '#E2E7EF',
    borderRadius: 22,
    borderWidth: 1,
    marginTop: 16,
    padding: 18,
  },
  sectionHeaderRow: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  textButton: {
    paddingHorizontal: 6,
    paddingVertical: 6,
  },
  textButtonLabel: {
    color: '#1D4ED8',
    fontSize: 14,
    fontWeight: '800',
  },
  pressed: {
    opacity: 0.68,
  },
  loadDescription: {
    color: '#111827',
    fontSize: 17,
    fontWeight: '800',
    lineHeight: 24,
    marginTop: 18,
  },
  tagRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
    marginTop: 13,
  },
  tag: {
    backgroundColor: '#F1F5F9',
    borderRadius: 999,
    paddingHorizontal: 11,
    paddingVertical: 7,
  },
  tagText: {
    color: '#475569',
    fontSize: 11,
    fontWeight: '800',
  },
  divider: {
    backgroundColor: '#E5E7EB',
    height: 1,
    marginVertical: 18,
  },
  serviceRow: {
    alignItems: 'flex-end',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  detailLabel: {
    color: '#6B7280',
    fontSize: 10,
    fontWeight: '900',
    letterSpacing: 0.7,
  },
  detailValue: {
    color: '#111827',
    fontSize: 17,
    fontWeight: '900',
    marginTop: 5,
  },
  priceContainer: {
    alignItems: 'flex-end',
    flex: 1,
    paddingLeft: 16,
  },
  priceValue: {
    color: '#1D4ED8',
    fontSize: 22,
    fontWeight: '900',
    marginTop: 5,
  },
  priceNote: {
    color: '#6B7280',
    fontSize: 12,
    lineHeight: 18,
    marginTop: 13,
  },
  offersCard: {
    backgroundColor: '#FFFFFF',
    borderColor: '#E2E7EF',
    borderRadius: 22,
    borderWidth: 1,
    marginTop: 16,
    padding: 18,
  },
  liveBadge: {
    alignItems: 'center',
    backgroundColor: '#F0FDF4',
    borderRadius: 999,
    flexDirection: 'row',
    paddingHorizontal: 9,
    paddingVertical: 7,
  },
  liveDot: {
    backgroundColor: '#16A34A',
    borderRadius: 999,
    height: 7,
    marginRight: 6,
    width: 7,
  },
  liveBadgeText: {
    color: '#15803D',
    fontSize: 9,
    fontWeight: '900',
    letterSpacing: 0.7,
  },
  emptyOfferState: {
    alignItems: 'center',
    backgroundColor: '#F8FAFC',
    borderRadius: 18,
    marginTop: 18,
    paddingHorizontal: 22,
    paddingVertical: 25,
  },
  searchIcon: {
    alignItems: 'center',
    backgroundColor: '#E8EEFF',
    borderRadius: 999,
    height: 48,
    justifyContent: 'center',
    width: 48,
  },
  searchIconText: {
    color: '#1D4ED8',
    fontSize: 25,
    fontWeight: '900',
  },
  emptyOfferTitle: {
    color: '#111827',
    fontSize: 16,
    fontWeight: '900',
    marginTop: 13,
  },
  emptyOfferDescription: {
    color: '#6B7280',
    fontSize: 13,
    lineHeight: 20,
    marginTop: 7,
    textAlign: 'center',
  },
  timelineCard: {
    backgroundColor: '#FFFFFF',
    borderColor: '#E2E7EF',
    borderRadius: 22,
    borderWidth: 1,
    marginTop: 16,
    padding: 18,
  },
  timelineList: {
    marginTop: 22,
  },
  timelineItem: {
    flexDirection: 'row',
  },
  timelineVisual: {
    alignItems: 'center',
    marginRight: 13,
    width: 26,
  },
  timelineDot: {
    alignItems: 'center',
    borderRadius: 999,
    height: 24,
    justifyContent: 'center',
    width: 24,
  },
  timelineDotCompleted: {
    backgroundColor: '#16A34A',
  },
  timelineDotCurrent: {
    backgroundColor: '#DBEAFE',
  },
  timelineDotPending: {
    backgroundColor: '#F1F5F9',
    borderColor: '#CBD5E1',
    borderWidth: 1,
  },
  timelineCheck: {
    color: '#FFFFFF',
    fontSize: 13,
    fontWeight: '900',
  },
  timelineCurrentInner: {
    backgroundColor: '#1D4ED8',
    borderRadius: 999,
    height: 9,
    width: 9,
  },
  timelineConnector: {
    backgroundColor: '#DCE3EE',
    flex: 1,
    marginVertical: 5,
    minHeight: 34,
    width: 2,
  },
  timelineText: {
    flex: 1,
  },
  timelineTextWithSpacing: {
    paddingBottom: 22,
  },
  timelineTitleRow: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  timelineTitle: {
    color: '#111827',
    flex: 1,
    fontSize: 14,
    fontWeight: '900',
    paddingRight: 12,
  },
  timelineTitlePending: {
    color: '#64748B',
  },
  timelineTime: {
    color: '#94A3B8',
    fontSize: 10,
    fontWeight: '700',
  },
  timelineDescription: {
    color: '#6B7280',
    fontSize: 12,
    lineHeight: 18,
    marginTop: 4,
  },
  actionsCard: {
    backgroundColor: '#FFFFFF',
    borderColor: '#E2E7EF',
    borderRadius: 22,
    borderWidth: 1,
    marginTop: 16,
    padding: 18,
  },
  supportButton: {
    alignItems: 'center',
    backgroundColor: '#1D4ED8',
    borderRadius: 15,
    justifyContent: 'center',
    marginTop: 18,
    minHeight: 54,
    paddingHorizontal: 18,
  },
  supportButtonPressed: {
    opacity: 0.84,
  },
  supportButtonText: {
    color: '#FFFFFF',
    fontSize: 15,
    fontWeight: '900',
  },
  cancelButton: {
    alignItems: 'center',
    backgroundColor: '#FFFFFF',
    borderColor: '#FCA5A5',
    borderRadius: 15,
    borderWidth: 1,
    justifyContent: 'center',
    marginTop: 11,
    minHeight: 52,
    paddingHorizontal: 18,
  },
  cancelButtonPressed: {
    backgroundColor: '#FEF2F2',
  },
  cancelButtonText: {
    color: '#DC2626',
    fontSize: 14,
    fontWeight: '900',
  },
  footerText: {
    color: '#6B7280',
    fontSize: 11,
    lineHeight: 17,
    marginTop: 16,
    textAlign: 'center',
  },
});
