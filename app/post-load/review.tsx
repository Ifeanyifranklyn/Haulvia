import { Stack, router, useLocalSearchParams } from 'expo-router';
import { useMemo, useState } from 'react';
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

type PricingSelectionPayload = {
  pickupLocation?: string;
  deliveryLocation?: string;
  description: string;
  category: string | null;
  quantity: number;
  weight: number | null;
  weightUnit: 'lb' | 'kg';
  dimensions: {
    length: number;
    width: number;
    height: number;
    unit: 'in' | 'cm';
  } | null;
  vehicleRequirement: string | null;
  specialInstructions: string | null;
  schedule: {
    pickupDate: string;
    pickupWindow:
      | 'morning'
      | 'afternoon'
      | 'evening'
      | 'flexible';
    deliveryPreference:
      | 'same-day'
      | 'next-day'
      | 'scheduled'
      | 'flexible';
    deliveryDate: string | null;
  };
  pricing: {
    serviceType: ServiceType;
    currency: 'CAD';
    selectedPrice: number;
    customerBudget: number | null;
    suggestedFlexRange: {
      minimum: number;
      maximum: number;
    };
    expeditedPrice: number;
    engineSnapshot: {
      ruleVersion: string;
      calculatedAt: string;
      assumptions: {
        estimatedDistanceKm: number;
        distanceSource: string;
      };
      expeditedComponents: Array<{
        code: string;
        label: string;
        amount: number;
      }>;
      flexComponents: Array<{
        code: string;
        label: string;
        amount: number;
      }>;
    };
  };
};

const PICKUP_WINDOW_LABELS: Record<
  PricingSelectionPayload['schedule']['pickupWindow'],
  string
> = {
  morning: 'Morning · 8:00 AM–12:00 PM',
  afternoon: 'Afternoon · 12:00 PM–5:00 PM',
  evening: 'Evening · 5:00 PM–9:00 PM',
  flexible: 'Flexible timing',
};

const DELIVERY_LABELS: Record<
  PricingSelectionPayload['schedule']['deliveryPreference'],
  string
> = {
  'same-day': 'Same-day delivery',
  'next-day': 'Next-day delivery',
  scheduled: 'Scheduled delivery',
  flexible: 'Flexible delivery',
};

function formatCurrency(value: number) {
  return new Intl.NumberFormat('en-CA', {
    style: 'currency',
    currency: 'CAD',
    minimumFractionDigits: 2,
  }).format(value);
}

function formatDate(value: string | null) {
  if (!value) {
    return 'Not specified';
  }

  const [year, month, day] = value.split('-').map(Number);
  const date = new Date(year, month - 1, day);

  return date.toLocaleDateString('en-CA', {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  });
}

function formatDimensions(
  dimensions: PricingSelectionPayload['dimensions'],
) {
  if (!dimensions) {
    return 'Not provided';
  }

  return `${dimensions.length} × ${dimensions.width} × ${dimensions.height} ${dimensions.unit}`;
}

function formatWeight(
  weight: number | null,
  unit: 'lb' | 'kg',
) {
  if (!weight) {
    return 'Not provided';
  }

  return `${weight} ${unit}`;
}

function SummaryRow({
  label,
  value,
  isLast = false,
}: {
  label: string;
  value: string;
  isLast?: boolean;
}) {
  return (
    <View
      style={[
        styles.summaryRow,
        !isLast && styles.summaryRowBorder,
      ]}
    >
      <Text style={styles.summaryRowLabel}>{label}</Text>

      <Text style={styles.summaryRowValue}>{value}</Text>
    </View>
  );
}

function SectionHeader({
  title,
  editLabel,
  onEdit,
}: {
  title: string;
  editLabel: string;
  onEdit: () => void;
}) {
  return (
    <View style={styles.sectionHeader}>
      <Text style={styles.sectionTitle}>{title}</Text>

      <Pressable
        accessibilityLabel={editLabel}
        accessibilityRole="button"
        hitSlop={10}
        onPress={onEdit}
        style={({ pressed }) => [
          styles.editButton,
          pressed && styles.pressed,
        ]}
      >
        <Text style={styles.editButtonText}>Edit</Text>
      </Pressable>
    </View>
  );
}

export default function ReviewScreen() {
  const params = useLocalSearchParams<{
    pricingSelection?: string;
  }>();

  const reviewDetails =
    useMemo<PricingSelectionPayload | null>(() => {
      const rawValue = Array.isArray(params.pricingSelection)
        ? params.pricingSelection[0]
        : params.pricingSelection;

      if (!rawValue) {
        return null;
      }

      try {
        return JSON.parse(
          rawValue,
        ) as PricingSelectionPayload;
      } catch {
        return null;
      }
    }, [params.pricingSelection]);

  const [isPosting, setIsPosting] = useState(false);

  const serviceName =
    reviewDetails?.pricing.serviceType === 'expedited'
      ? 'Expedited'
      : 'Flex';

  const serviceBadge =
    reviewDetails?.pricing.serviceType === 'expedited'
      ? 'FASTEST'
      : 'BEST VALUE';

  const handlePostLoad = async () => {
    if (!reviewDetails || isPosting) {
      return;
    }

    setIsPosting(true);

    try {
      /*
       * Temporary MVP behavior.
       *
       * This is where the app will later:
       * 1. Save the load to the backend.
       * 2. Save the immutable pricing snapshot.
       * 3. Create the marketplace posting.
       * 4. Notify eligible drivers.
       * 5. Record the pricing-intelligence event.
       */

      await new Promise((resolve) =>
        setTimeout(resolve, 700),
      );

      Alert.alert(
        'Load posted',
        reviewDetails.pricing.serviceType === 'expedited'
          ? 'Your Expedited load is ready for priority driver matching.'
          : 'Your Flex load is ready to receive driver offers.',
        [
          {
            text: 'Done',
            onPress: () =>
              router.replace({
                pathname: '/post-load/success',
                params: {
                  serviceType: reviewDetails.pricing.serviceType,
                  price: String(reviewDetails.pricing.selectedPrice),
                },
              })
          },
        ],
      );
    } catch {
      Alert.alert(
        'Unable to post load',
        'Something went wrong. Please try again.',
      );
    } finally {
      setIsPosting(false);
    }
  };

  return (
    <>
      <Stack.Screen
        options={{
          title: 'Review',
          headerBackTitle: 'Pricing',
        }}
      />

      <SafeAreaView style={styles.container}>
        <StatusBar barStyle="dark-content" />

        <ScrollView
          contentContainerStyle={styles.content}
          showsVerticalScrollIndicator={false}
        >
          <View style={styles.progressHeader}>
            <Text style={styles.step}>STEP 5 OF 5</Text>
            <Text style={styles.progressPercent}>100%</Text>
          </View>

          <View style={styles.progressTrack}>
            <View style={styles.progressFill} />
          </View>

          <Text style={styles.title}>
            Review your load
          </Text>

          <Text style={styles.subtitle}>
            Confirm the details below before posting your load
            to Haulvia.
          </Text>

          {!reviewDetails ? (
            <View style={styles.dataErrorCard}>
              <Text style={styles.dataErrorTitle}>
                Load information is unavailable
              </Text>

              <Text style={styles.dataErrorText}>
                Go back and complete the previous steps again.
              </Text>
            </View>
          ) : (
            <>
              <View style={styles.routeCard}>
                <SectionHeader
                  editLabel="Edit pickup and delivery"
                  onEdit={() =>
                    router.push('/post-load')
                  }
                  title="Route"
                />

                <View style={styles.routeItem}>
                  <View style={styles.pickupMarker} />

                  <View style={styles.routeTextContainer}>
                    <Text style={styles.routeLabel}>
                      Pickup
                    </Text>

                    <Text style={styles.routeValue}>
                      {reviewDetails.pickupLocation ||
                        'Not provided'}
                    </Text>
                  </View>
                </View>

                <View style={styles.routeConnector} />

                <View style={styles.routeItem}>
                  <View style={styles.deliveryMarker} />

                  <View style={styles.routeTextContainer}>
                    <Text style={styles.routeLabel}>
                      Delivery
                    </Text>

                    <Text style={styles.routeValue}>
                      {reviewDetails.deliveryLocation ||
                        'Not provided'}
                    </Text>
                  </View>
                </View>
              </View>

              <View style={styles.sectionCard}>
                <SectionHeader
                  editLabel="Edit load details"
                  onEdit={() => router.back()}
                  title="Load details"
                />

                <SummaryRow
                  label="Item"
                  value={reviewDetails.description}
                />

                <SummaryRow
                  label="Category"
                  value={
                    reviewDetails.category ||
                    'Not specified'
                  }
                />

                <SummaryRow
                  label="Quantity"
                  value={`${reviewDetails.quantity} item${
                    reviewDetails.quantity === 1 ? '' : 's'
                  }`}
                />

                <SummaryRow
                  label="Weight"
                  value={formatWeight(
                    reviewDetails.weight,
                    reviewDetails.weightUnit,
                  )}
                />

                <SummaryRow
                  label="Dimensions"
                  value={formatDimensions(
                    reviewDetails.dimensions,
                  )}
                />

                <SummaryRow
                  label="Vehicle"
                  value={
                    reviewDetails.vehicleRequirement ||
                    'Haulvia recommendation'
                  }
                />

                <SummaryRow
                  isLast
                  label="Instructions"
                  value={
                    reviewDetails.specialInstructions ||
                    'None'
                  }
                />
              </View>

              <View style={styles.sectionCard}>
                <SectionHeader
                  editLabel="Edit schedule"
                  onEdit={() => router.back()}
                  title="Schedule"
                />

                <SummaryRow
                  label="Pickup date"
                  value={formatDate(
                    reviewDetails.schedule.pickupDate,
                  )}
                />

                <SummaryRow
                  label="Pickup window"
                  value={
                    PICKUP_WINDOW_LABELS[
                      reviewDetails.schedule.pickupWindow
                    ]
                  }
                />

                <SummaryRow
                  label="Delivery timing"
                  value={
                    DELIVERY_LABELS[
                      reviewDetails.schedule
                        .deliveryPreference
                    ]
                  }
                />

                <SummaryRow
                  isLast
                  label="Delivery date"
                  value={formatDate(
                    reviewDetails.schedule.deliveryDate,
                  )}
                />
              </View>

              <View
                style={[
                  styles.serviceCard,
                  reviewDetails.pricing.serviceType ===
                  'flex'
                    ? styles.flexServiceCard
                    : styles.expeditedServiceCard,
                ]}
              >
                <SectionHeader
                  editLabel="Edit service and pricing"
                  onEdit={() => router.back()}
                  title="Service and pricing"
                />

                <View style={styles.serviceTopRow}>
                  <View>
                    <Text style={styles.serviceName}>
                      {serviceName}
                    </Text>

                    <Text style={styles.serviceDescription}>
                      {reviewDetails.pricing.serviceType ===
                      'expedited'
                        ? 'Priority pickup and direct priority delivery.'
                        : 'Customer budget with driver offers and counteroffers.'}
                    </Text>
                  </View>

                  <View
                    style={[
                      styles.serviceBadge,
                      reviewDetails.pricing.serviceType ===
                      'flex'
                        ? styles.flexBadge
                        : styles.expeditedBadge,
                    ]}
                  >
                    <Text
                      style={[
                        styles.serviceBadgeText,
                        reviewDetails.pricing.serviceType ===
                        'flex'
                          ? styles.flexBadgeText
                          : styles.expeditedBadgeText,
                      ]}
                    >
                      {serviceBadge}
                    </Text>
                  </View>
                </View>

                <View style={styles.priceDivider} />

                <View style={styles.priceRow}>
                  <View>
                    <Text style={styles.priceLabel}>
                      {reviewDetails.pricing.serviceType ===
                      'expedited'
                        ? 'Estimated fixed price'
                        : 'Your budget'}
                    </Text>

                    <Text style={styles.priceNote}>
                      {reviewDetails.pricing.serviceType ===
                      'expedited'
                        ? 'Before applicable taxes'
                        : 'Drivers may submit counteroffers'}
                    </Text>
                  </View>

                  <Text style={styles.priceValue}>
                    {formatCurrency(
                      reviewDetails.pricing.selectedPrice,
                    )}
                  </Text>
                </View>
              </View>

              <View style={styles.noticeCard}>
                <Text style={styles.noticeTitle}>
                  Before you post
                </Text>

                <Text style={styles.noticeText}>
                  By posting this load, you confirm that the
                  information provided is accurate and that the
                  item is safe and legal to transport.
                </Text>

                <Text style={styles.noticeText}>
                  No payment is taken at this stage. Payment and
                  final service confirmation will occur after the
                  applicable driver acceptance process.
                </Text>
              </View>

              <Text style={styles.engineNote}>
                Pricing snapshot:{' '}
                {
                  reviewDetails.pricing.engineSnapshot
                    .ruleVersion
                }
              </Text>
            </>
          )}

          <Pressable
            accessibilityLabel="Post load"
            accessibilityRole="button"
            disabled={!reviewDetails || isPosting}
            onPress={handlePostLoad}
            style={({ pressed }) => [
              styles.postButton,
              (!reviewDetails || isPosting) &&
                styles.postButtonDisabled,
              pressed &&
                reviewDetails &&
                !isPosting &&
                styles.postButtonPressed,
            ]}
          >
            <Text style={styles.postButtonText}>
              {isPosting
                ? 'Posting load...'
                : reviewDetails?.pricing.serviceType ===
                    'expedited'
                  ? 'Post Expedited load →'
                  : 'Post Flex load →'}
            </Text>
          </Pressable>

          <Text style={styles.footerText}>
            You can review driver details before confirming the
            delivery.
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
    paddingTop: 24,
  },
  progressHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  step: {
    color: '#1D4ED8',
    fontSize: 13,
    fontWeight: '800',
    letterSpacing: 1,
  },
  progressPercent: {
    color: '#6B7280',
    fontSize: 13,
    fontWeight: '700',
  },
  progressTrack: {
    backgroundColor: '#DDE5F3',
    borderRadius: 999,
    height: 6,
    marginTop: 12,
    overflow: 'hidden',
  },
  progressFill: {
    backgroundColor: '#1D4ED8',
    borderRadius: 999,
    height: '100%',
    width: '100%',
  },
  title: {
    color: '#111827',
    fontSize: 34,
    fontWeight: '800',
    lineHeight: 41,
    marginTop: 30,
  },
  subtitle: {
    color: '#6B7280',
    fontSize: 17,
    lineHeight: 26,
    marginTop: 12,
  },
  routeCard: {
    backgroundColor: '#FFFFFF',
    borderColor: '#E2E7EF',
    borderRadius: 20,
    borderWidth: 1,
    marginTop: 28,
    padding: 18,
  },
  sectionCard: {
    backgroundColor: '#FFFFFF',
    borderColor: '#E2E7EF',
    borderRadius: 20,
    borderWidth: 1,
    marginTop: 16,
    overflow: 'hidden',
    paddingHorizontal: 18,
    paddingTop: 18,
  },
  sectionHeader: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 16,
  },
  sectionTitle: {
    color: '#111827',
    fontSize: 18,
    fontWeight: '800',
  },
  editButton: {
    backgroundColor: '#EEF3FF',
    borderRadius: 999,
    paddingHorizontal: 13,
    paddingVertical: 7,
  },
  editButtonText: {
    color: '#1D4ED8',
    fontSize: 12,
    fontWeight: '800',
  },
  pressed: {
    opacity: 0.72,
  },
  routeItem: {
    alignItems: 'flex-start',
    flexDirection: 'row',
  },
  pickupMarker: {
    backgroundColor: '#1D4ED8',
    borderRadius: 999,
    height: 12,
    marginRight: 14,
    marginTop: 5,
    width: 12,
  },
  deliveryMarker: {
    backgroundColor: '#16A34A',
    borderRadius: 3,
    height: 12,
    marginRight: 14,
    marginTop: 5,
    width: 12,
  },
  routeConnector: {
    backgroundColor: '#CBD5E1',
    height: 28,
    marginLeft: 5,
    marginVertical: 5,
    width: 2,
  },
  routeTextContainer: {
    flex: 1,
  },
  routeLabel: {
    color: '#6B7280',
    fontSize: 11,
    fontWeight: '800',
    textTransform: 'uppercase',
  },
  routeValue: {
    color: '#111827',
    fontSize: 15,
    fontWeight: '700',
    lineHeight: 21,
    marginTop: 4,
  },
  summaryRow: {
    paddingVertical: 15,
  },
  summaryRowBorder: {
    borderBottomColor: '#E5E7EB',
    borderBottomWidth: 1,
  },
  summaryRowLabel: {
    color: '#6B7280',
    fontSize: 12,
    fontWeight: '700',
    textTransform: 'uppercase',
  },
  summaryRowValue: {
    color: '#111827',
    fontSize: 15,
    fontWeight: '700',
    lineHeight: 21,
    marginTop: 5,
  },
  serviceCard: {
    borderRadius: 20,
    borderWidth: 1,
    marginTop: 16,
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
    alignItems: 'flex-start',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  serviceName: {
    color: '#111827',
    fontSize: 22,
    fontWeight: '900',
  },
  serviceDescription: {
    color: '#6B7280',
    fontSize: 13,
    lineHeight: 19,
    marginTop: 5,
    maxWidth: 230,
  },
  serviceBadge: {
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
  serviceBadgeText: {
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
  priceDivider: {
    backgroundColor: '#CBD5E1',
    height: 1,
    marginVertical: 18,
  },
  priceRow: {
    alignItems: 'flex-end',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  priceLabel: {
    color: '#111827',
    fontSize: 14,
    fontWeight: '800',
  },
  priceNote: {
    color: '#6B7280',
    fontSize: 11,
    marginTop: 4,
  },
  priceValue: {
    color: '#1D4ED8',
    fontSize: 27,
    fontWeight: '900',
  },
  noticeCard: {
    backgroundColor: '#FFFBEB',
    borderColor: '#FDE68A',
    borderRadius: 18,
    borderWidth: 1,
    marginTop: 16,
    padding: 18,
  },
  noticeTitle: {
    color: '#92400E',
    fontSize: 16,
    fontWeight: '800',
  },
  noticeText: {
    color: '#78350F',
    fontSize: 13,
    lineHeight: 20,
    marginTop: 10,
  },
  engineNote: {
    color: '#9CA3AF',
    fontSize: 10,
    marginTop: 14,
    textAlign: 'center',
  },
  dataErrorCard: {
    backgroundColor: '#FEF2F2',
    borderColor: '#FECACA',
    borderRadius: 16,
    borderWidth: 1,
    marginTop: 26,
    padding: 18,
  },
  dataErrorTitle: {
    color: '#991B1B',
    fontSize: 15,
    fontWeight: '800',
  },
  dataErrorText: {
    color: '#B91C1C',
    fontSize: 13,
    lineHeight: 19,
    marginTop: 5,
  },
  postButton: {
    alignItems: 'center',
    backgroundColor: '#1D4ED8',
    borderRadius: 16,
    justifyContent: 'center',
    marginTop: 28,
    minHeight: 60,
    paddingHorizontal: 20,
  },
  postButtonDisabled: {
    backgroundColor: '#94A3B8',
  },
  postButtonPressed: {
    opacity: 0.84,
    transform: [{ scale: 0.99 }],
  },
  postButtonText: {
    color: '#FFFFFF',
    fontSize: 17,
    fontWeight: '800',
  },
  footerText: {
    color: '#6B7280',
    fontSize: 12,
    lineHeight: 18,
    marginTop: 12,
    textAlign: 'center',
  },
});