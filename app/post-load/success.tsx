import { Stack, router, useLocalSearchParams } from 'expo-router';
import { useMemo } from 'react';
import {
  Pressable,
  SafeAreaView,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  View,
} from 'react-native';

type ServiceType = 'expedited' | 'flex';

const TEMPORARY_LOAD_NUMBER = 'HV-20260722-0001';

function firstParam(value: string | string[] | undefined) {
  return Array.isArray(value) ? value[0] : value;
}

export default function LoadSuccessScreen() {
  const params = useLocalSearchParams<{
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

  const serviceType = useMemo<ServiceType>(() => {
    return firstParam(params.serviceType) === 'flex'
      ? 'flex'
      : 'expedited';
  }, [params.serviceType]);

  const selectedPrice = useMemo(() => {
    const parsedValue = Number(firstParam(params.price));

    return Number.isFinite(parsedValue) ? parsedValue : null;
  }, [params.price]);

  const isExpedited = serviceType === 'expedited';

  const formattedPrice =
    selectedPrice !== null
      ? new Intl.NumberFormat('en-CA', {
          style: 'currency',
          currency: 'CAD',
          minimumFractionDigits: 2,
        }).format(selectedPrice)
      : null;

  const handleViewLoad = () => {
    router.replace({
      pathname: '/loads/[loadId]',
      params: {
        loadId: TEMPORARY_LOAD_NUMBER,
        serviceType,
        price:
          selectedPrice !== null
            ? String(selectedPrice)
            : undefined,
        pickupLocation:
          firstParam(params.pickupLocation) ?? undefined,
        deliveryLocation:
          firstParam(params.deliveryLocation) ?? undefined,
        description: firstParam(params.description) ?? undefined,
        category: firstParam(params.category) ?? undefined,
        quantity: firstParam(params.quantity) ?? undefined,
        vehicleRequirement:
          firstParam(params.vehicleRequirement) ?? undefined,
        pickupDate: firstParam(params.pickupDate) ?? undefined,
        deliveryDate:
          firstParam(params.deliveryDate) ?? undefined,
      },
    });
  };

  const handlePostAnotherLoad = () => {
    router.replace('/post-load');
  };

  return (
    <>
      <Stack.Screen
        options={{
          headerBackVisible: false,
          title: 'Load posted',
          gestureEnabled: false,
        }}
      />

      <SafeAreaView style={styles.container}>
        <StatusBar barStyle="dark-content" />

        <ScrollView
          contentContainerStyle={styles.content}
          showsVerticalScrollIndicator={false}
        >
          <View style={styles.successIconContainer}>
            <View style={styles.successIconOuter}>
              <View style={styles.successIconInner}>
                <Text style={styles.successIcon}>✓</Text>
              </View>
            </View>
          </View>

          <Text style={styles.eyebrow}>LOAD POSTED</Text>
          <Text style={styles.title}>Your load is live</Text>

          <Text style={styles.referenceNumber}>
            {TEMPORARY_LOAD_NUMBER}
          </Text>

          <Text style={styles.subtitle}>
            {isExpedited
              ? 'Haulvia is now prioritizing your load for qualified drivers.'
              : 'Your load is now available for qualified drivers to review and submit offers.'}
          </Text>

          <View
            style={[
              styles.serviceCard,
              isExpedited
                ? styles.expeditedServiceCard
                : styles.flexServiceCard,
            ]}
          >
            <View style={styles.serviceTopRow}>
              <View style={styles.serviceIdentity}>
                <View style={styles.serviceIconContainer}>
                  <Text style={styles.serviceIcon}>
                    {isExpedited ? '⚡' : '↔'}
                  </Text>
                </View>

                <View style={styles.serviceTextContainer}>
                  <Text style={styles.serviceLabel}>
                    Selected service
                  </Text>

                  <Text style={styles.serviceName}>
                    {isExpedited ? 'Expedited' : 'Flex'}
                  </Text>
                </View>
              </View>

              <View
                style={[
                  styles.badge,
                  isExpedited
                    ? styles.expeditedBadge
                    : styles.flexBadge,
                ]}
              >
                <Text
                  style={[
                    styles.badgeText,
                    isExpedited
                      ? styles.expeditedBadgeText
                      : styles.flexBadgeText,
                  ]}
                >
                  {isExpedited ? 'FASTEST' : 'BEST VALUE'}
                </Text>
              </View>
            </View>

            {formattedPrice ? (
              <View style={styles.priceRow}>
                <View style={styles.priceTextContainer}>
                  <Text style={styles.priceLabel}>
                    {isExpedited
                      ? 'Estimated fixed price'
                      : 'Your posted budget'}
                  </Text>

                  <Text style={styles.priceNote}>
                    {isExpedited
                      ? 'Before applicable taxes'
                      : 'Drivers may submit counteroffers'}
                  </Text>
                </View>

                <Text style={styles.priceValue}>
                  {formattedPrice}
                </Text>
              </View>
            ) : null}
          </View>

          <View style={styles.statusCard}>
            <Text style={styles.statusTitle}>
              What happens next?
            </Text>

            <View style={styles.timelineItem}>
              <View style={styles.timelineLeft}>
                <View style={styles.activeTimelineDot}>
                  <Text style={styles.completedCheck}>✓</Text>
                </View>
                <View style={styles.timelineLine} />
              </View>

              <View style={styles.timelineContent}>
                <Text style={styles.timelineLabel}>
                  Load posted
                </Text>

                <Text style={styles.timelineDescription}>
                  Your load details have been submitted to Haulvia.
                </Text>
              </View>
            </View>

            <View style={styles.timelineItem}>
              <View style={styles.timelineLeft}>
                <View style={styles.currentTimelineDot}>
                  <View style={styles.currentTimelineDotInner} />
                </View>
                <View style={styles.timelineLine} />
              </View>

              <View style={styles.timelineContent}>
                <Text style={styles.timelineLabel}>
                  {isExpedited
                    ? 'Priority driver matching'
                    : 'Receive driver offers'}
                </Text>

                <Text style={styles.timelineDescription}>
                  {isExpedited
                    ? 'Qualified drivers are being notified based on vehicle, location, and availability.'
                    : 'Qualified drivers can accept your budget or submit a counteroffer.'}
                </Text>
              </View>
            </View>

            <View style={styles.timelineItem}>
              <View style={styles.timelineLeft}>
                <View style={styles.pendingTimelineDot}>
                  <Text style={styles.timelineNumber}>3</Text>
                </View>
              </View>

              <View style={styles.timelineContent}>
                <Text style={styles.timelineLabel}>
                  Review and confirm
                </Text>

                <Text style={styles.timelineDescription}>
                  Review the driver, vehicle, price, and service
                  details before final confirmation.
                </Text>
              </View>
            </View>
          </View>

          <View style={styles.notificationCard}>
            <View style={styles.notificationIconContainer}>
              <Text style={styles.notificationIcon}>!</Text>
            </View>

            <View style={styles.notificationTextContainer}>
              <Text style={styles.notificationTitle}>
                We’ll keep you updated
              </Text>

              <Text style={styles.notificationDescription}>
                You’ll receive a notification when there is a
                driver update or action requiring your attention.
              </Text>
            </View>
          </View>

          <Pressable
            accessibilityLabel="View posted load"
            accessibilityRole="button"
            onPress={handleViewLoad}
            style={({ pressed }) => [
              styles.primaryButton,
              pressed && styles.primaryButtonPressed,
            ]}
          >
            <Text style={styles.primaryButtonText}>
              View posted load →
            </Text>
          </Pressable>

          <Pressable
            accessibilityLabel="Post another load"
            accessibilityRole="button"
            onPress={handlePostAnotherLoad}
            style={({ pressed }) => [
              styles.secondaryButton,
              pressed && styles.secondaryButtonPressed,
            ]}
          >
            <Text style={styles.secondaryButtonText}>
              Post another load
            </Text>
          </Pressable>

          <Text style={styles.footerText}>
            No payment has been taken yet.
          </Text>
        </ScrollView>
      </SafeAreaView>
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F7F9FC',
  },
  content: {
    flexGrow: 1,
    paddingBottom: 40,
    paddingHorizontal: 24,
    paddingTop: 34,
  },
  successIconContainer: {
    alignItems: 'center',
  },
  successIconOuter: {
    alignItems: 'center',
    backgroundColor: '#DCFCE7',
    borderRadius: 999,
    height: 110,
    justifyContent: 'center',
    width: 110,
  },
  successIconInner: {
    alignItems: 'center',
    backgroundColor: '#16A34A',
    borderRadius: 999,
    height: 70,
    justifyContent: 'center',
    width: 70,
  },
  successIcon: {
    color: '#FFFFFF',
    fontSize: 39,
    fontWeight: '900',
  },
  eyebrow: {
    color: '#16A34A',
    fontSize: 13,
    fontWeight: '900',
    letterSpacing: 1.2,
    marginTop: 25,
    textAlign: 'center',
  },
  title: {
    color: '#111827',
    fontSize: 36,
    fontWeight: '900',
    lineHeight: 43,
    marginTop: 10,
    textAlign: 'center',
  },
  referenceNumber: {
    color: '#1D4ED8',
    fontSize: 14,
    fontWeight: '800',
    letterSpacing: 0.5,
    marginTop: 8,
    textAlign: 'center',
  },
  subtitle: {
    color: '#6B7280',
    fontSize: 17,
    lineHeight: 26,
    marginTop: 12,
    textAlign: 'center',
  },
  serviceCard: {
    borderRadius: 22,
    borderWidth: 1,
    marginTop: 30,
    padding: 18,
  },
  expeditedServiceCard: {
    backgroundColor: '#EEF3FF',
    borderColor: '#BFDBFE',
  },
  flexServiceCard: {
    backgroundColor: '#F0FDF4',
    borderColor: '#BBF7D0',
  },
  serviceTopRow: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  serviceIdentity: {
    alignItems: 'center',
    flex: 1,
    flexDirection: 'row',
    paddingRight: 10,
  },
  serviceIconContainer: {
    alignItems: 'center',
    backgroundColor: '#FFFFFF',
    borderRadius: 14,
    height: 50,
    justifyContent: 'center',
    marginRight: 12,
    width: 50,
  },
  serviceIcon: {
    color: '#1D4ED8',
    fontSize: 22,
    fontWeight: '900',
  },
  serviceTextContainer: {
    flex: 1,
  },
  serviceLabel: {
    color: '#6B7280',
    fontSize: 11,
    fontWeight: '800',
    textTransform: 'uppercase',
  },
  serviceName: {
    color: '#111827',
    fontSize: 21,
    fontWeight: '900',
    marginTop: 3,
  },
  badge: {
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 7,
  },
  expeditedBadge: {
    backgroundColor: '#DBEAFE',
  },
  flexBadge: {
    backgroundColor: '#DCFCE7',
  },
  badgeText: {
    fontSize: 10,
    fontWeight: '900',
    letterSpacing: 0.6,
  },
  expeditedBadgeText: {
    color: '#1D4ED8',
  },
  flexBadgeText: {
    color: '#15803D',
  },
  priceRow: {
    alignItems: 'flex-end',
    borderTopColor: '#CBD5E1',
    borderTopWidth: 1,
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginTop: 18,
    paddingTop: 17,
  },
  priceTextContainer: {
    flex: 1,
    paddingRight: 12,
  },
  priceLabel: {
    color: '#111827',
    fontSize: 13,
    fontWeight: '800',
  },
  priceNote: {
    color: '#6B7280',
    fontSize: 11,
    marginTop: 4,
  },
  priceValue: {
    color: '#1D4ED8',
    fontSize: 25,
    fontWeight: '900',
  },
  statusCard: {
    backgroundColor: '#FFFFFF',
    borderColor: '#E2E7EF',
    borderRadius: 22,
    borderWidth: 1,
    marginTop: 18,
    padding: 19,
  },
  statusTitle: {
    color: '#111827',
    fontSize: 19,
    fontWeight: '900',
    marginBottom: 20,
  },
  timelineItem: {
    flexDirection: 'row',
  },
  timelineLeft: {
    alignItems: 'center',
    marginRight: 14,
    width: 28,
  },
  activeTimelineDot: {
    alignItems: 'center',
    backgroundColor: '#16A34A',
    borderRadius: 999,
    height: 24,
    justifyContent: 'center',
    width: 24,
  },
  completedCheck: {
    color: '#FFFFFF',
    fontSize: 13,
    fontWeight: '900',
  },
  currentTimelineDot: {
    alignItems: 'center',
    backgroundColor: '#DBEAFE',
    borderRadius: 999,
    height: 24,
    justifyContent: 'center',
    width: 24,
  },
  currentTimelineDotInner: {
    backgroundColor: '#1D4ED8',
    borderRadius: 999,
    height: 10,
    width: 10,
  },
  pendingTimelineDot: {
    alignItems: 'center',
    backgroundColor: '#F1F5F9',
    borderColor: '#CBD5E1',
    borderRadius: 999,
    borderWidth: 1,
    height: 24,
    justifyContent: 'center',
    width: 24,
  },
  timelineNumber: {
    color: '#64748B',
    fontSize: 11,
    fontWeight: '900',
  },
  timelineLine: {
    backgroundColor: '#DCE3EE',
    flex: 1,
    marginVertical: 5,
    minHeight: 35,
    width: 2,
  },
  timelineContent: {
    flex: 1,
    paddingBottom: 24,
  },
  timelineLabel: {
    color: '#111827',
    fontSize: 15,
    fontWeight: '900',
  },
  timelineDescription: {
    color: '#6B7280',
    fontSize: 13,
    lineHeight: 19,
    marginTop: 5,
  },
  notificationCard: {
    alignItems: 'flex-start',
    backgroundColor: '#FFFBEB',
    borderColor: '#FDE68A',
    borderRadius: 18,
    borderWidth: 1,
    flexDirection: 'row',
    marginTop: 18,
    padding: 17,
  },
  notificationIconContainer: {
    alignItems: 'center',
    backgroundColor: '#FEF3C7',
    borderRadius: 12,
    height: 42,
    justifyContent: 'center',
    marginRight: 12,
    width: 42,
  },
  notificationIcon: {
    color: '#92400E',
    fontSize: 18,
    fontWeight: '900',
  },
  notificationTextContainer: {
    flex: 1,
  },
  notificationTitle: {
    color: '#92400E',
    fontSize: 14,
    fontWeight: '900',
  },
  notificationDescription: {
    color: '#78350F',
    fontSize: 12,
    lineHeight: 18,
    marginTop: 5,
  },
  primaryButton: {
    alignItems: 'center',
    backgroundColor: '#1D4ED8',
    borderRadius: 16,
    justifyContent: 'center',
    marginTop: 28,
    minHeight: 60,
    paddingHorizontal: 20,
  },
  primaryButtonPressed: {
    opacity: 0.84,
    transform: [{ scale: 0.99 }],
  },
  primaryButtonText: {
    color: '#FFFFFF',
    fontSize: 17,
    fontWeight: '900',
  },
  secondaryButton: {
    alignItems: 'center',
    backgroundColor: '#FFFFFF',
    borderColor: '#CBD5E1',
    borderRadius: 16,
    borderWidth: 1,
    justifyContent: 'center',
    marginTop: 12,
    minHeight: 58,
    paddingHorizontal: 20,
  },
  secondaryButtonPressed: {
    backgroundColor: '#F1F5F9',
  },
  secondaryButtonText: {
    color: '#1D4ED8',
    fontSize: 16,
    fontWeight: '900',
  },
  footerText: {
    color: '#6B7280',
    fontSize: 12,
    marginTop: 14,
    textAlign: 'center',
  },
});
