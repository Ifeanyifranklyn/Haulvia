import { Stack, useLocalSearchParams } from 'expo-router';
import { useEffect, useMemo, useRef, useState } from 'react';
import {
    Alert,
    KeyboardAvoidingView,
    Modal,
    Platform,
    Pressable,
    SafeAreaView,
    ScrollView,
    StatusBar,
    StyleSheet,
    Text,
    TextInput,
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

type OfferStatus =
  | 'ACTIVE'
  | 'COUNTERED'
  | 'ACCEPTED'
  | 'DECLINED'
  | 'EXPIRED';

type DriverOffer = {
  id: string;
  driverName: string;
  driverInitials: string;
  rating: number;
  completedDeliveries: number;
  vehicle: string;
  pickupEtaMinutes: number;
  amount: number;
  typicalResponseMinutes: number;
};

const MAX_POSTER_COUNTERS = 2;
const DEMO_OFFER_DURATION_SECONDS = 15 * 60;

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

function formatCountdown(totalSeconds: number) {
  const safeSeconds = Math.max(0, totalSeconds);
  const minutes = Math.floor(safeSeconds / 60);
  const seconds = safeSeconds % 60;

  return `${minutes}:${seconds.toString().padStart(2, '0')}`;
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

  const loadNumber = firstParam(params.loadId) ?? 'HV-20260722-0001';

  const serviceType: ServiceType =
    firstParam(params.serviceType) === 'expedited' ? 'expedited' : 'flex';

  const isExpedited = serviceType === 'expedited';

  const selectedPrice = useMemo(() => {
    const parsedPrice = Number(firstParam(params.price));
    return Number.isFinite(parsedPrice) ? parsedPrice : null;
  }, [params.price]);

  const pickupLocation =
    firstParam(params.pickupLocation) ?? 'Pickup location will appear here';
  const deliveryLocation =
    firstParam(params.deliveryLocation) ?? 'Delivery location will appear here';
  const description = firstParam(params.description) ?? 'Posted load';
  const category = firstParam(params.category) ?? 'General load';
  const quantity = firstParam(params.quantity) ?? '1';
  const vehicleRequirement =
    firstParam(params.vehicleRequirement) ?? 'Not specified';
  const pickupDate = firstParam(params.pickupDate) ?? 'To be confirmed';
  const deliveryDate = firstParam(params.deliveryDate) ?? 'To be confirmed';

  const demoOffer = useMemo<DriverOffer>(
    () => ({
      id: 'offer-demo-001',
      driverName: 'John D.',
      driverInitials: 'JD',
      rating: 4.9,
      completedDeliveries: 87,
      vehicle:
        vehicleRequirement === 'Not specified'
          ? 'Pickup truck'
          : vehicleRequirement,
      pickupEtaMinutes: 18,
      amount:
        selectedPrice === null
          ? 121.5
          : Math.max(
              selectedPrice + 3.5,
              Number((selectedPrice * 1.03).toFixed(2)),
            ),
      typicalResponseMinutes: 6,
    }),
    [selectedPrice, vehicleRequirement],
  );

  /*
   * Demo-only local state. Replace this with offer data returned by the
   * Haulvia backend. Expedited loads do not receive negotiable offers.
   */
  const [offerStatus, setOfferStatus] = useState<OfferStatus>(
    isExpedited ? 'DECLINED' : 'ACTIVE',
  );
  const [posterCounterCount, setPosterCounterCount] = useState(0);
  const [lastCounterAmount, setLastCounterAmount] = useState<number | null>(null);
  const [counterModalVisible, setCounterModalVisible] = useState(false);
  const [counterAmountInput, setCounterAmountInput] = useState('');
  const [counterError, setCounterError] = useState('');

  const offerExpiresAtRef = useRef(
    Date.now() + DEMO_OFFER_DURATION_SECONDS * 1000,
  );
  const [remainingSeconds, setRemainingSeconds] = useState(
    DEMO_OFFER_DURATION_SECONDS,
  );

  useEffect(() => {
    if (offerStatus !== 'ACTIVE' && offerStatus !== 'COUNTERED') {
      return;
    }

    const updateCountdown = () => {
      const secondsRemaining = Math.max(
        0,
        Math.ceil((offerExpiresAtRef.current - Date.now()) / 1000),
      );

      setRemainingSeconds(secondsRemaining);

      if (secondsRemaining === 0) {
        setOfferStatus('EXPIRED');
      }
    };

    updateCountdown();
    const intervalId = setInterval(updateCountdown, 1000);

    return () => clearInterval(intervalId);
  }, [offerStatus]);

  const timeline = useMemo<TimelineEvent[]>(() => {
    const baseTimeline: TimelineEvent[] = [
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
    ];

    if (offerStatus === 'ACCEPTED') {
      return [
        ...baseTimeline,
        {
          id: 'matching',
          title: 'Driver offer accepted',
          description: `${demoOffer.driverName} was selected at ${formatCurrency(
            lastCounterAmount ?? demoOffer.amount,
          )}.`,
          time: 'Just now',
          state: 'completed',
        },
        {
          id: 'selected',
          title: 'Driver selected',
          description: 'The assigned driver and vehicle are confirmed.',
          time: 'Just now',
          state: 'completed',
        },
        {
          id: 'pickup',
          title: 'Pickup confirmed',
          description:
            'Pickup verification will be recorded after collection.',
          state: 'current',
        },
        {
          id: 'delivered',
          title: 'Delivered',
          description:
            'Delivery confirmation and proof of delivery will appear here.',
          state: 'pending',
        },
      ];
    }

    return [
      ...baseTimeline,
      {
        id: 'matching',
        title: isExpedited
          ? 'Priority driver matching'
          : offerStatus === 'COUNTERED'
            ? 'Counter-offer pending'
            : offerStatus === 'EXPIRED'
              ? 'Offer expired'
              : 'Looking for drivers',
        description: isExpedited
          ? 'Nearby qualified drivers are being prioritized for this load.'
          : offerStatus === 'COUNTERED'
            ? `Waiting for ${demoOffer.driverName} to respond to your counter-offer.`
            : offerStatus === 'EXPIRED'
              ? 'The previous offer expired. Haulvia is continuing to notify qualified drivers.'
              : 'Qualified drivers are being notified and can submit offers.',
        state: offerStatus === 'EXPIRED' ? 'completed' : 'current',
      },
      {
        id: 'selected',
        title: 'Driver selected',
        description: 'The selected driver and vehicle will appear here.',
        state: 'pending',
      },
      {
        id: 'pickup',
        title: 'Pickup confirmed',
        description: 'Pickup verification will be recorded after collection.',
        state: 'pending',
      },
      {
        id: 'delivered',
        title: 'Delivered',
        description:
          'Delivery confirmation and proof of delivery will appear here.',
        state: 'pending',
      },
    ];
  }, [
    demoOffer.amount,
    demoOffer.driverName,
    isExpedited,
    lastCounterAmount,
    offerStatus,
  ]);

  const canCounter =
    offerStatus === 'ACTIVE' && posterCounterCount < MAX_POSTER_COUNTERS;

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
        { text: 'Keep Load', style: 'cancel' },
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

  const handleViewOffer = () => {
    Alert.alert(
      `${demoOffer.driverName}'s offer`,
      [
        `Rating: ${demoOffer.rating.toFixed(1)}`,
        `Completed deliveries: ${demoOffer.completedDeliveries}`,
        `Vehicle: ${demoOffer.vehicle}`,
        `Pickup ETA: ${demoOffer.pickupEtaMinutes} minutes`,
        `Offer: ${formatCurrency(demoOffer.amount)}`,
        `Typical response: within ${demoOffer.typicalResponseMinutes} minutes`,
      ].join('\n'),
    );
  };

  const handleAcceptOffer = () => {
    const acceptedAmount = lastCounterAmount ?? demoOffer.amount;

    Alert.alert(
      'Accept this offer?',
      `${demoOffer.driverName} will be assigned at ${formatCurrency(
        acceptedAmount,
      )}. Acceptance locks the agreed price.`,
      [
        { text: 'Not Yet', style: 'cancel' },
        {
          text: 'Accept Offer',
          onPress: () => setOfferStatus('ACCEPTED'),
        },
      ],
    );
  };

  const handleDeclineOffer = () => {
    Alert.alert(
      'Decline this offer?',
      'The offer will be closed and the driver will be notified.',
      [
        { text: 'Keep Offer', style: 'cancel' },
        {
          text: 'Decline',
          style: 'destructive',
          onPress: () => setOfferStatus('DECLINED'),
        },
      ],
    );
  };

  const handleOpenCounterModal = () => {
    if (!canCounter) {
      return;
    }

    const suggestedCounter =
      selectedPrice !== null && selectedPrice < demoOffer.amount
        ? selectedPrice
        : Math.max(1, demoOffer.amount - 2);

    setCounterAmountInput(suggestedCounter.toFixed(2));
    setCounterError('');
    setCounterModalVisible(true);
  };

  const handleCloseCounterModal = () => {
    setCounterModalVisible(false);
    setCounterError('');
  };

  const handleSendCounter = () => {
    const parsedCounter = Number(counterAmountInput);

    if (!Number.isFinite(parsedCounter) || parsedCounter <= 0) {
      setCounterError('Enter a valid counter-offer amount.');
      return;
    }

    if (parsedCounter >= demoOffer.amount) {
      setCounterError(
        `Your counter must be below ${formatCurrency(demoOffer.amount)}.`,
      );
      return;
    }

    if (posterCounterCount >= MAX_POSTER_COUNTERS) {
      setCounterError(
        'You have used both counter-offers for this negotiation.',
      );
      return;
    }

    setPosterCounterCount((currentCount) => currentCount + 1);
    setLastCounterAmount(parsedCounter);
    setOfferStatus('COUNTERED');
    setCounterModalVisible(false);
    setCounterError('');

    Alert.alert(
      'Counter-offer sent',
      `${formatCurrency(parsedCounter)} was sent to ${
        demoOffer.driverName
      }. The offer timer is still running.`,
    );
  };

  const renderNoOffersState = () => (
    <View style={styles.emptyOfferState}>
      <View style={styles.searchIcon}>
        <Text style={styles.searchIconText}>⌕</Text>
      </View>

      <Text style={styles.emptyOfferTitle}>
        {offerStatus === 'EXPIRED'
          ? 'Offer expired'
          : offerStatus === 'DECLINED'
            ? 'No active offers'
            : 'No offers yet'}
      </Text>

      <Text style={styles.emptyOfferDescription}>
        {isExpedited
          ? 'Haulvia is prioritizing nearby qualified drivers for this load.'
          : offerStatus === 'EXPIRED'
            ? 'The previous offer expired. Qualified nearby drivers are still being notified.'
            : offerStatus === 'DECLINED'
              ? 'The declined offer is closed. We will alert you when another driver responds.'
              : "Qualified nearby drivers are being notified. We'll alert you when an offer arrives."}
      </Text>
    </View>
  );

  const renderActiveOffer = () => {
    const isWaitingForDriver = offerStatus === 'COUNTERED';

    return (
      <View style={styles.offerContainer}>
        <View style={styles.offerTimerRow}>
          <View style={styles.timerBadge}>
            <Text style={styles.timerBadgeLabel}>OFFER EXPIRES IN</Text>
            <Text style={styles.timerBadgeValue}>
              {formatCountdown(remainingSeconds)}
            </Text>
          </View>

          <Text style={styles.counterUsageText}>
            {posterCounterCount} of {MAX_POSTER_COUNTERS} counters used
          </Text>
        </View>

        <View style={styles.driverOfferCard}>
          <View style={styles.driverHeaderRow}>
            <View style={styles.driverIdentity}>
              <View style={styles.driverAvatar}>
                <Text style={styles.driverAvatarText}>
                  {demoOffer.driverInitials}
                </Text>
              </View>

              <View style={styles.driverTextContainer}>
                <View style={styles.driverNameRow}>
                  <Text style={styles.driverName}>{demoOffer.driverName}</Text>
                  <View style={styles.verifiedBadge}>
                    <Text style={styles.verifiedBadgeText}>VERIFIED</Text>
                  </View>
                </View>

                <Text style={styles.driverRating}>
                  ★ {demoOffer.rating.toFixed(1)} ·{' '}
                  {demoOffer.completedDeliveries} deliveries
                </Text>
              </View>
            </View>

            <Pressable
              accessibilityLabel="View driver offer details"
              accessibilityRole="button"
              onPress={handleViewOffer}
              style={({ pressed }) => [
                styles.offerDetailsButton,
                pressed && styles.pressed,
              ]}
            >
              <Text style={styles.offerDetailsButtonText}>Details</Text>
            </Pressable>
          </View>

          <View style={styles.offerFactsRow}>
            <View style={styles.offerFact}>
              <Text style={styles.offerFactLabel}>VEHICLE</Text>
              <Text numberOfLines={1} style={styles.offerFactValue}>
                {demoOffer.vehicle}
              </Text>
            </View>

            <View style={styles.offerFactDivider} />

            <View style={styles.offerFact}>
              <Text style={styles.offerFactLabel}>PICKUP ETA</Text>
              <Text style={styles.offerFactValue}>
                {demoOffer.pickupEtaMinutes} min
              </Text>
            </View>
          </View>

          <View style={styles.responseTimeRow}>
            <Text style={styles.responseTimeLabel}>Typical response time</Text>
            <Text style={styles.responseTimeValue}>
              Usually within {demoOffer.typicalResponseMinutes} minutes
            </Text>
          </View>

          <View style={styles.offerAmountRow}>
            <View>
              <Text style={styles.offerAmountLabel}>DRIVER OFFER</Text>
              <Text style={styles.offerAmountValue}>
                {formatCurrency(demoOffer.amount)}
              </Text>
            </View>

            {lastCounterAmount !== null ? (
              <View style={styles.counterAmountContainer}>
                <Text style={styles.offerAmountLabel}>YOUR COUNTER</Text>
                <Text style={styles.counterAmountValue}>
                  {formatCurrency(lastCounterAmount)}
                </Text>
              </View>
            ) : null}
          </View>

          {isWaitingForDriver ? (
            <View style={styles.waitingState}>
              <View style={styles.waitingDot} />
              <View style={styles.waitingTextContainer}>
                <Text style={styles.waitingTitle}>
                  Waiting for driver's response
                </Text>
                <Text style={styles.waitingDescription}>
                  The driver can accept, revise, or decline before the timer
                  expires.
                </Text>
              </View>
            </View>
          ) : (
            <>
              <Pressable
                accessibilityLabel="Accept driver offer"
                accessibilityRole="button"
                onPress={handleAcceptOffer}
                style={({ pressed }) => [
                  styles.acceptOfferButton,
                  pressed && styles.acceptOfferButtonPressed,
                ]}
              >
                <Text style={styles.acceptOfferButtonText}>Accept offer</Text>
              </Pressable>

              <View style={styles.secondaryActionRow}>
                <Pressable
                  accessibilityLabel="Send a counter-offer"
                  accessibilityRole="button"
                  disabled={!canCounter}
                  onPress={handleOpenCounterModal}
                  style={({ pressed }) => [
                    styles.counterOfferButton,
                    !canCounter && styles.counterOfferButtonDisabled,
                    pressed && canCounter && styles.secondaryButtonPressed,
                  ]}
                >
                  <Text
                    style={[
                      styles.counterOfferButtonText,
                      !canCounter && styles.counterOfferButtonTextDisabled,
                    ]}
                  >
                    Counter offer
                  </Text>
                </Pressable>

                <Pressable
                  accessibilityLabel="Decline driver offer"
                  accessibilityRole="button"
                  onPress={handleDeclineOffer}
                  style={({ pressed }) => [
                    styles.declineOfferButton,
                    pressed && styles.secondaryButtonPressed,
                  ]}
                >
                  <Text style={styles.declineOfferButtonText}>Decline</Text>
                </Pressable>
              </View>
            </>
          )}

          {posterCounterCount >= MAX_POSTER_COUNTERS ? (
            <Text style={styles.counterLimitMessage}>
              Both poster counter-offers have been used for this negotiation.
            </Text>
          ) : null}
        </View>
      </View>
    );
  };

  const renderAssignedDriver = () => {
    const acceptedAmount = lastCounterAmount ?? demoOffer.amount;

    return (
      <View style={styles.assignedDriverCard}>
        <View style={styles.assignedHeaderRow}>
          <View style={styles.driverIdentity}>
            <View style={styles.assignedAvatar}>
              <Text style={styles.assignedAvatarText}>
                {demoOffer.driverInitials}
              </Text>
            </View>

            <View style={styles.driverTextContainer}>
              <Text style={styles.assignedLabel}>ASSIGNED DRIVER</Text>
              <Text style={styles.assignedDriverName}>
                {demoOffer.driverName}
              </Text>
              <Text style={styles.driverRating}>
                ★ {demoOffer.rating.toFixed(1)} · {demoOffer.vehicle}
              </Text>
            </View>
          </View>

          <View style={styles.confirmedBadge}>
            <Text style={styles.confirmedBadgeText}>CONFIRMED</Text>
          </View>
        </View>

        <View style={styles.assignedFactsRow}>
          <View style={styles.assignedFact}>
            <Text style={styles.offerFactLabel}>AGREED PRICE</Text>
            <Text style={styles.assignedFactValue}>
              {formatCurrency(acceptedAmount)}
            </Text>
          </View>

          <View style={styles.offerFactDivider} />

          <View style={styles.assignedFact}>
            <Text style={styles.offerFactLabel}>PICKUP ETA</Text>
            <Text style={styles.assignedFactValue}>
              {demoOffer.pickupEtaMinutes} min
            </Text>
          </View>
        </View>

        <Pressable
          accessibilityLabel="Track assigned driver"
          accessibilityRole="button"
          onPress={() => {
            Alert.alert(
              'Live tracking',
              'Driver tracking will be connected after the driver workflow is built.',
            );
          }}
          style={({ pressed }) => [
            styles.trackDriverButton,
            pressed && styles.acceptOfferButtonPressed,
          ]}
        >
          <Text style={styles.trackDriverButtonText}>Track driver</Text>
        </Pressable>
      </View>
    );
  };

  const activeOfferCount =
    offerStatus === 'ACTIVE' || offerStatus === 'COUNTERED' ? 1 : 0;

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
              <Text style={styles.referenceLabel}>SHIPMENT NUMBER</Text>

              <Text
                numberOfLines={1}
                adjustsFontSizeToFit
                minimumFontScale={0.85}
                style={styles.referenceNumber}
              >
                {loadNumber}
              </Text>

              <Text style={styles.postedTime}>Posted just now</Text>
            </View>
          </View>

          <View style={styles.statusBadgeRow}>
            <View
              style={[
                styles.statusBadge,
                offerStatus === 'ACCEPTED' && styles.statusBadgeConfirmed,
              ]}
            >
              <View
                style={[
                  styles.statusDot,
                  offerStatus === 'ACCEPTED' && styles.statusDotConfirmed,
                ]}
              />
              <Text
                style={[
                  styles.statusBadgeText,
                  offerStatus === 'ACCEPTED' &&
                    styles.statusBadgeTextConfirmed,
                ]}
              >
                {offerStatus === 'ACCEPTED'
                  ? 'DRIVER ASSIGNED'
                  : 'LOOKING FOR DRIVERS'}
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
                <Text style={styles.routeValue}>{pickupLocation}</Text>
                <Text style={styles.routeDate}>{pickupDate}</Text>
              </View>
            </View>

            <View style={styles.routeItem}>
              <View style={styles.routeVisual}>
                <View style={styles.deliveryDot} />
              </View>

              <View style={styles.routeTextContainer}>
                <Text style={styles.routeLabel}>DELIVERY</Text>
                <Text style={styles.routeValue}>{deliveryLocation}</Text>
                <Text style={styles.routeDate}>{deliveryDate}</Text>
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

            <Text style={styles.loadDescription}>{description}</Text>

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
                <Text style={styles.tagText}>{vehicleRequirement}</Text>
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
                : 'Drivers can accept your budget or submit an offer.'}
            </Text>
          </View>

          <View style={styles.offersCard}>
            <View style={styles.sectionHeaderRow}>
              <View>
                <Text style={styles.sectionTitle}>
                  {offerStatus === 'ACCEPTED'
                    ? 'Assigned driver'
                    : isExpedited
                      ? 'Driver matching'
                      : 'Driver offers'}
                </Text>

                <Text style={styles.sectionSubtitle}>
                  {offerStatus === 'ACCEPTED'
                    ? 'Your driver has been confirmed'
                    : isExpedited
                      ? 'Priority matching is active'
                      : `${activeOfferCount} ${
                          activeOfferCount === 1
                            ? 'active offer'
                            : 'active offers'
                        }`}
                </Text>
              </View>

              {offerStatus !== 'ACCEPTED' ? (
                <View style={styles.liveBadge}>
                  <View style={styles.liveDot} />
                  <Text style={styles.liveBadgeText}>LIVE</Text>
                </View>
              ) : null}
            </View>

            {offerStatus === 'ACCEPTED'
              ? renderAssignedDriver()
              : offerStatus === 'ACTIVE' || offerStatus === 'COUNTERED'
                ? renderActiveOffer()
                : renderNoOffersState()}
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
                          event.state === 'current' && styles.timelineDotCurrent,
                          event.state === 'pending' && styles.timelineDotPending,
                        ]}
                      >
                        {event.state === 'completed' ? (
                          <Text style={styles.timelineCheck}>✓</Text>
                        ) : event.state === 'current' ? (
                          <View style={styles.timelineCurrentInner} />
                        ) : null}
                      </View>

                      {!isLast ? <View style={styles.timelineConnector} /> : null}
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
                          <Text style={styles.timelineTime}>{event.time}</Text>
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
              <Text style={styles.supportButtonText}>Contact support</Text>
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
              <Text style={styles.cancelButtonText}>Cancel load</Text>
            </Pressable>
          </View>

          <Text style={styles.footerText}>
            Use {loadNumber} when contacting support about this load.
          </Text>
        </ScrollView>
      </SafeAreaView>

      <Modal
        animationType="slide"
        onRequestClose={handleCloseCounterModal}
        transparent
        visible={counterModalVisible}
      >
        <KeyboardAvoidingView
          behavior={Platform.OS === 'ios' ? 'padding' : undefined}
          style={styles.modalKeyboardView}
        >
          <Pressable
            onPress={handleCloseCounterModal}
            style={styles.modalBackdrop}
          />

          <View style={styles.counterSheet}>
            <View style={styles.sheetHandle} />

            <View style={styles.counterSheetHeader}>
              <View style={styles.counterSheetTitleContainer}>
                <Text style={styles.counterSheetTitle}>
                  Send counter-offer
                </Text>
                <Text style={styles.counterSheetSubtitle}>
                  You can counter this driver a maximum of two times.
                </Text>
              </View>

              <Pressable
                accessibilityLabel="Close counter-offer"
                accessibilityRole="button"
                onPress={handleCloseCounterModal}
                style={({ pressed }) => [
                  styles.closeSheetButton,
                  pressed && styles.pressed,
                ]}
              >
                <Text style={styles.closeSheetButtonText}>×</Text>
              </Pressable>
            </View>

            <View style={styles.negotiationSummary}>
              <View style={styles.negotiationSummaryItem}>
                <Text style={styles.negotiationSummaryLabel}>
                  POSTED BUDGET
                </Text>
                <Text style={styles.negotiationSummaryValue}>
                  {formatCurrency(selectedPrice)}
                </Text>
              </View>

              <View style={styles.negotiationSummaryDivider} />

              <View style={styles.negotiationSummaryItem}>
                <Text style={styles.negotiationSummaryLabel}>
                  DRIVER OFFER
                </Text>
                <Text style={styles.negotiationSummaryValue}>
                  {formatCurrency(demoOffer.amount)}
                </Text>
              </View>
            </View>

            <Text style={styles.counterInputLabel}>YOUR COUNTER</Text>

            <View
              style={[
                styles.counterInputContainer,
                counterError ? styles.counterInputContainerError : null,
              ]}
            >
              <Text style={styles.currencyPrefix}>$</Text>
              <TextInput
                accessibilityLabel="Counter-offer amount"
                autoFocus
                keyboardType="decimal-pad"
                onChangeText={(value) => {
                  setCounterAmountInput(value.replace(/[^0-9.]/g, ''));
                  setCounterError('');
                }}
                placeholder="0.00"
                placeholderTextColor="#94A3B8"
                selectionColor="#1D4ED8"
                style={styles.counterInput}
                value={counterAmountInput}
              />
              <Text style={styles.currencyCode}>CAD</Text>
            </View>

            {counterError ? (
              <Text style={styles.counterErrorText}>{counterError}</Text>
            ) : null}

            <View style={styles.counterRuleBox}>
              <Text style={styles.counterRuleTitle}>Negotiation rules</Text>
              <Text style={styles.counterRuleText}>
                This will use counter-offer{' '}
                {Math.min(posterCounterCount + 1, MAX_POSTER_COUNTERS)} of{' '}
                {MAX_POSTER_COUNTERS}. The current offer timer continues after
                your counter is sent.
              </Text>
            </View>

            <Pressable
              accessibilityLabel="Send counter-offer"
              accessibilityRole="button"
              onPress={handleSendCounter}
              style={({ pressed }) => [
                styles.sendCounterButton,
                pressed && styles.acceptOfferButtonPressed,
              ]}
            >
              <Text style={styles.sendCounterButtonText}>
                Send counter-offer
              </Text>
            </Pressable>
          </View>
        </KeyboardAvoidingView>
      </Modal>
    </>
  );
}

const styles = StyleSheet.create({
  container: { backgroundColor: '#F7F9FC', flex: 1 },
  content: { paddingBottom: 44, paddingHorizontal: 20, paddingTop: 24 },
  headingRow: { flexDirection: 'row' },
  headingTextContainer: { flex: 1 },
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
  statusBadgeRow: { alignItems: 'flex-start', marginTop: 8 },
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
  statusBadgeConfirmed: { backgroundColor: '#F0FDF4', borderColor: '#BBF7D0' },
  statusDot: {
    backgroundColor: '#1D4ED8',
    borderRadius: 999,
    height: 7,
    marginRight: 6,
    width: 7,
  },
  statusDotConfirmed: { backgroundColor: '#16A34A' },
  statusBadgeText: {
    color: '#1D4ED8',
    fontSize: 9,
    fontWeight: '900',
    letterSpacing: 0.45,
  },
  statusBadgeTextConfirmed: { color: '#15803D' },
  postedTime: { color: '#6B7280', fontSize: 13, marginTop: 7 },
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
  sectionTitle: { color: '#111827', fontSize: 19, fontWeight: '900' },
  sectionSubtitle: {
    color: '#6B7280',
    fontSize: 12,
    lineHeight: 18,
    marginTop: 4,
  },
  routeItem: { flexDirection: 'row' },
  routeVisual: { alignItems: 'center', marginRight: 14, width: 18 },
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
  routeTextContainer: { flex: 1, paddingBottom: 20 },
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
  routeDate: { color: '#6B7280', fontSize: 12, marginTop: 4 },
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
  textButton: { paddingHorizontal: 6, paddingVertical: 6 },
  textButtonLabel: { color: '#1D4ED8', fontSize: 14, fontWeight: '800' },
  pressed: { opacity: 0.68 },
  loadDescription: {
    color: '#111827',
    fontSize: 17,
    fontWeight: '800',
    lineHeight: 24,
    marginTop: 18,
  },
  tagRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginTop: 13 },
  tag: {
    backgroundColor: '#F1F5F9',
    borderRadius: 999,
    paddingHorizontal: 11,
    paddingVertical: 7,
  },
  tagText: { color: '#475569', fontSize: 11, fontWeight: '800' },
  divider: { backgroundColor: '#E5E7EB', height: 1, marginVertical: 18 },
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
  detailValue: { color: '#111827', fontSize: 17, fontWeight: '900', marginTop: 5 },
  priceContainer: { alignItems: 'flex-end', flex: 1, paddingLeft: 16 },
  priceValue: { color: '#1D4ED8', fontSize: 22, fontWeight: '900', marginTop: 5 },
  priceNote: { color: '#6B7280', fontSize: 12, lineHeight: 18, marginTop: 13 },
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
  searchIconText: { color: '#1D4ED8', fontSize: 25, fontWeight: '900' },
  emptyOfferTitle: { color: '#111827', fontSize: 16, fontWeight: '900', marginTop: 13 },
  emptyOfferDescription: {
    color: '#6B7280',
    fontSize: 13,
    lineHeight: 20,
    marginTop: 7,
    textAlign: 'center',
  },
  offerContainer: { marginTop: 18 },
  offerTimerRow: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  timerBadge: {
    alignItems: 'center',
    backgroundColor: '#FFF7ED',
    borderColor: '#FED7AA',
    borderRadius: 12,
    borderWidth: 1,
    flexDirection: 'row',
    paddingHorizontal: 10,
    paddingVertical: 8,
  },
  timerBadgeLabel: {
    color: '#9A3412',
    fontSize: 8,
    fontWeight: '900',
    letterSpacing: 0.55,
  },
  timerBadgeValue: { color: '#C2410C', fontSize: 12, fontWeight: '900', marginLeft: 7 },
  counterUsageText: {
    color: '#64748B',
    fontSize: 10,
    fontWeight: '700',
    marginLeft: 10,
    textAlign: 'right',
  },
  driverOfferCard: {
    backgroundColor: '#F8FAFC',
    borderColor: '#E2E8F0',
    borderRadius: 18,
    borderWidth: 1,
    marginTop: 12,
    padding: 15,
  },
  driverHeaderRow: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  driverIdentity: { alignItems: 'center', flex: 1, flexDirection: 'row' },
  driverAvatar: {
    alignItems: 'center',
    backgroundColor: '#DBEAFE',
    borderRadius: 999,
    height: 46,
    justifyContent: 'center',
    width: 46,
  },
  driverAvatarText: { color: '#1D4ED8', fontSize: 14, fontWeight: '900' },
  driverTextContainer: { flex: 1, marginLeft: 11 },
  driverNameRow: { alignItems: 'center', flexDirection: 'row', flexWrap: 'wrap' },
  driverName: { color: '#111827', fontSize: 16, fontWeight: '900' },
  verifiedBadge: {
    backgroundColor: '#ECFDF5',
    borderRadius: 999,
    marginLeft: 7,
    paddingHorizontal: 7,
    paddingVertical: 4,
  },
  verifiedBadgeText: {
    color: '#15803D',
    fontSize: 7,
    fontWeight: '900',
    letterSpacing: 0.45,
  },
  driverRating: { color: '#64748B', fontSize: 11, fontWeight: '700', marginTop: 4 },
  offerDetailsButton: { marginLeft: 8, paddingHorizontal: 5, paddingVertical: 7 },
  offerDetailsButtonText: { color: '#1D4ED8', fontSize: 12, fontWeight: '900' },
  offerFactsRow: {
    alignItems: 'stretch',
    backgroundColor: '#FFFFFF',
    borderRadius: 14,
    flexDirection: 'row',
    marginTop: 15,
    paddingHorizontal: 13,
    paddingVertical: 12,
  },
  offerFact: { flex: 1 },
  offerFactDivider: { backgroundColor: '#E2E8F0', marginHorizontal: 14, width: 1 },
  offerFactLabel: {
    color: '#64748B',
    fontSize: 8,
    fontWeight: '900',
    letterSpacing: 0.55,
  },
  offerFactValue: { color: '#111827', fontSize: 13, fontWeight: '900', marginTop: 5 },
  responseTimeRow: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginTop: 14,
  },
  responseTimeLabel: { color: '#64748B', fontSize: 11 },
  responseTimeValue: {
    color: '#334155',
    fontSize: 11,
    fontWeight: '800',
    marginLeft: 12,
    textAlign: 'right',
  },
  offerAmountRow: {
    alignItems: 'flex-end',
    borderTopColor: '#E2E8F0',
    borderTopWidth: 1,
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginTop: 14,
    paddingTop: 14,
  },
  offerAmountLabel: {
    color: '#64748B',
    fontSize: 9,
    fontWeight: '900',
    letterSpacing: 0.65,
  },
  offerAmountValue: { color: '#111827', fontSize: 24, fontWeight: '900', marginTop: 5 },
  counterAmountContainer: { alignItems: 'flex-end', flex: 1, paddingLeft: 14 },
  counterAmountValue: { color: '#1D4ED8', fontSize: 19, fontWeight: '900', marginTop: 5 },
  acceptOfferButton: {
    alignItems: 'center',
    backgroundColor: '#1D4ED8',
    borderRadius: 14,
    justifyContent: 'center',
    marginTop: 16,
    minHeight: 50,
    paddingHorizontal: 16,
  },
  acceptOfferButtonPressed: { opacity: 0.84 },
  acceptOfferButtonText: { color: '#FFFFFF', fontSize: 14, fontWeight: '900' },
  secondaryActionRow: { flexDirection: 'row', gap: 10, marginTop: 10 },
  counterOfferButton: {
    alignItems: 'center',
    backgroundColor: '#FFFFFF',
    borderColor: '#93C5FD',
    borderRadius: 14,
    borderWidth: 1,
    flex: 1,
    justifyContent: 'center',
    minHeight: 48,
    paddingHorizontal: 10,
  },
  counterOfferButtonDisabled: { backgroundColor: '#F1F5F9', borderColor: '#CBD5E1' },
  counterOfferButtonText: { color: '#1D4ED8', fontSize: 13, fontWeight: '900' },
  counterOfferButtonTextDisabled: { color: '#94A3B8' },
  declineOfferButton: {
    alignItems: 'center',
    backgroundColor: '#FFFFFF',
    borderColor: '#FCA5A5',
    borderRadius: 14,
    borderWidth: 1,
    flex: 1,
    justifyContent: 'center',
    minHeight: 48,
    paddingHorizontal: 10,
  },
  declineOfferButtonText: { color: '#DC2626', fontSize: 13, fontWeight: '900' },
  secondaryButtonPressed: { opacity: 0.72 },
  waitingState: {
    alignItems: 'flex-start',
    backgroundColor: '#EFF6FF',
    borderColor: '#BFDBFE',
    borderRadius: 14,
    borderWidth: 1,
    flexDirection: 'row',
    marginTop: 16,
    padding: 13,
  },
  waitingDot: { backgroundColor: '#1D4ED8', borderRadius: 999, height: 8, marginTop: 5, width: 8 },
  waitingTextContainer: { flex: 1, marginLeft: 10 },
  waitingTitle: { color: '#1E3A8A', fontSize: 12, fontWeight: '900' },
  waitingDescription: { color: '#475569', fontSize: 11, lineHeight: 17, marginTop: 3 },
  counterLimitMessage: {
    color: '#9A3412',
    fontSize: 10,
    lineHeight: 16,
    marginTop: 11,
    textAlign: 'center',
  },
  assignedDriverCard: {
    backgroundColor: '#F0FDF4',
    borderColor: '#BBF7D0',
    borderRadius: 18,
    borderWidth: 1,
    marginTop: 18,
    padding: 15,
  },
  assignedHeaderRow: {
    alignItems: 'flex-start',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  assignedAvatar: {
    alignItems: 'center',
    backgroundColor: '#DCFCE7',
    borderRadius: 999,
    height: 48,
    justifyContent: 'center',
    width: 48,
  },
  assignedAvatarText: { color: '#15803D', fontSize: 14, fontWeight: '900' },
  assignedLabel: {
    color: '#15803D',
    fontSize: 8,
    fontWeight: '900',
    letterSpacing: 0.65,
  },
  assignedDriverName: { color: '#111827', fontSize: 17, fontWeight: '900', marginTop: 3 },
  confirmedBadge: {
    backgroundColor: '#DCFCE7',
    borderRadius: 999,
    marginLeft: 8,
    paddingHorizontal: 8,
    paddingVertical: 6,
  },
  confirmedBadgeText: {
    color: '#15803D',
    fontSize: 8,
    fontWeight: '900',
    letterSpacing: 0.5,
  },
  assignedFactsRow: {
    backgroundColor: '#FFFFFF',
    borderRadius: 14,
    flexDirection: 'row',
    marginTop: 16,
    padding: 13,
  },
  assignedFact: { flex: 1 },
  assignedFactValue: { color: '#111827', fontSize: 15, fontWeight: '900', marginTop: 5 },
  trackDriverButton: {
    alignItems: 'center',
    backgroundColor: '#15803D',
    borderRadius: 14,
    justifyContent: 'center',
    marginTop: 14,
    minHeight: 50,
  },
  trackDriverButtonText: { color: '#FFFFFF', fontSize: 14, fontWeight: '900' },
  timelineCard: {
    backgroundColor: '#FFFFFF',
    borderColor: '#E2E7EF',
    borderRadius: 22,
    borderWidth: 1,
    marginTop: 16,
    padding: 18,
  },
  timelineList: { marginTop: 22 },
  timelineItem: { flexDirection: 'row' },
  timelineVisual: { alignItems: 'center', marginRight: 13, width: 26 },
  timelineDot: {
    alignItems: 'center',
    borderRadius: 999,
    height: 24,
    justifyContent: 'center',
    width: 24,
  },
  timelineDotCompleted: { backgroundColor: '#16A34A' },
  timelineDotCurrent: { backgroundColor: '#DBEAFE' },
  timelineDotPending: { backgroundColor: '#F1F5F9', borderColor: '#CBD5E1', borderWidth: 1 },
  timelineCheck: { color: '#FFFFFF', fontSize: 13, fontWeight: '900' },
  timelineCurrentInner: { backgroundColor: '#1D4ED8', borderRadius: 999, height: 9, width: 9 },
  timelineConnector: {
    backgroundColor: '#DCE3EE',
    flex: 1,
    marginVertical: 5,
    minHeight: 34,
    width: 2,
  },
  timelineText: { flex: 1 },
  timelineTextWithSpacing: { paddingBottom: 22 },
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
  timelineTitlePending: { color: '#64748B' },
  timelineTime: { color: '#94A3B8', fontSize: 10, fontWeight: '700' },
  timelineDescription: { color: '#6B7280', fontSize: 12, lineHeight: 18, marginTop: 4 },
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
  supportButtonPressed: { opacity: 0.84 },
  supportButtonText: { color: '#FFFFFF', fontSize: 15, fontWeight: '900' },
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
  cancelButtonPressed: { backgroundColor: '#FEF2F2' },
  cancelButtonText: { color: '#DC2626', fontSize: 14, fontWeight: '900' },
  footerText: {
    color: '#6B7280',
    fontSize: 11,
    lineHeight: 17,
    marginTop: 16,
    textAlign: 'center',
  },
  modalKeyboardView: { flex: 1, justifyContent: 'flex-end' },
  modalBackdrop: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(15, 23, 42, 0.46)',
  },
  counterSheet: {
    backgroundColor: '#FFFFFF',
    borderTopLeftRadius: 26,
    borderTopRightRadius: 26,
    paddingBottom: 28,
    paddingHorizontal: 20,
    paddingTop: 10,
  },
  sheetHandle: {
    alignSelf: 'center',
    backgroundColor: '#CBD5E1',
    borderRadius: 999,
    height: 4,
    width: 42,
  },
  counterSheetHeader: { alignItems: 'flex-start', flexDirection: 'row', marginTop: 18 },
  counterSheetTitleContainer: { flex: 1, paddingRight: 12 },
  counterSheetTitle: { color: '#111827', fontSize: 21, fontWeight: '900' },
  counterSheetSubtitle: { color: '#64748B', fontSize: 12, lineHeight: 18, marginTop: 5 },
  closeSheetButton: {
    alignItems: 'center',
    backgroundColor: '#F1F5F9',
    borderRadius: 999,
    height: 34,
    justifyContent: 'center',
    width: 34,
  },
  closeSheetButtonText: { color: '#475569', fontSize: 23, lineHeight: 24 },
  negotiationSummary: {
    backgroundColor: '#F8FAFC',
    borderRadius: 16,
    flexDirection: 'row',
    marginTop: 20,
    padding: 14,
  },
  negotiationSummaryItem: { flex: 1 },
  negotiationSummaryDivider: { backgroundColor: '#E2E8F0', marginHorizontal: 14, width: 1 },
  negotiationSummaryLabel: {
    color: '#64748B',
    fontSize: 8,
    fontWeight: '900',
    letterSpacing: 0.55,
  },
  negotiationSummaryValue: { color: '#111827', fontSize: 16, fontWeight: '900', marginTop: 5 },
  counterInputLabel: {
    color: '#475569',
    fontSize: 10,
    fontWeight: '900',
    letterSpacing: 0.65,
    marginTop: 20,
  },
  counterInputContainer: {
    alignItems: 'center',
    borderColor: '#CBD5E1',
    borderRadius: 15,
    borderWidth: 1,
    flexDirection: 'row',
    marginTop: 8,
    minHeight: 58,
    paddingHorizontal: 14,
  },
  counterInputContainerError: { borderColor: '#DC2626' },
  currencyPrefix: { color: '#111827', fontSize: 22, fontWeight: '900' },
  counterInput: {
    color: '#111827',
    flex: 1,
    fontSize: 22,
    fontWeight: '900',
    marginLeft: 6,
    paddingVertical: 10,
  },
  currencyCode: { color: '#64748B', fontSize: 11, fontWeight: '900' },
  counterErrorText: { color: '#DC2626', fontSize: 11, lineHeight: 17, marginTop: 7 },
  counterRuleBox: {
    backgroundColor: '#FFF7ED',
    borderColor: '#FED7AA',
    borderRadius: 14,
    borderWidth: 1,
    marginTop: 16,
    padding: 13,
  },
  counterRuleTitle: { color: '#9A3412', fontSize: 11, fontWeight: '900' },
  counterRuleText: { color: '#7C2D12', fontSize: 11, lineHeight: 17, marginTop: 4 },
  sendCounterButton: {
    alignItems: 'center',
    backgroundColor: '#1D4ED8',
    borderRadius: 15,
    justifyContent: 'center',
    marginTop: 18,
    minHeight: 54,
  },
  sendCounterButtonText: { color: '#FFFFFF', fontSize: 15, fontWeight: '900' },
});
